#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
glm::vec3 *dev_dummyPos;
glm::vec3 *dev_dummyVel1;
// needed for use with thrust
//thrust::device_ptr<int> dev_thrust_particleArrayIndices;
//thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  // makes the cell width twice the maximum search radius
  gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance); 
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // TODO-2.1 TODO-2.3 - Allocate additional buffers here.
  cudaMalloc((void**)&dev_particleArrayIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");

  cudaMalloc((void**)&dev_particleGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");

  cudaMalloc((void**)&dev_dummyPos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_dummyPos failed!");

  cudaMalloc((void**)&dev_dummyVel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_dummyVel1 failed!");

  cudaMalloc((void**)&dev_gridCellStartIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");

  cudaMalloc((void**)&dev_gridCellEndIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridEndStartIndices failed!");

  // end of my code
  cudaDeviceSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaDeviceSynchronize();
}


/******************
* stepSimulation *
******************/

/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel) {
  glm::vec3 thisPos = pos[iSelf];
  glm::vec3 thisVel = vel[iSelf];
  glm::vec3 perceivedCenter = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 separation = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 cohesion = glm::vec3(0.0f, 0.0f, 0.0f);
  int neighborCount = 0;
  for (int b = 0; b < N; b++) {
    if (b == iSelf) {
      continue;
    }
    glm::vec3 bPos = pos[b];
    glm::vec3 bVel = vel[b];
    float distance = glm::length(thisPos - bPos);
    // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
    if (distance < rule1Distance) {
      perceivedCenter += bPos;
      neighborCount += 1;
    }
    // Rule 2: boids try to stay a distance d away from each other
    if (distance < rule2Distance) {
      separation -= (bPos - thisPos);
    }
    // Rule 3: boids try to match the speed of surrounding boids
    if (distance < rule3Distance) {
      cohesion += bVel;
    }
  }
  if (neighborCount > 0) {
    perceivedCenter /= neighborCount;
    cohesion /= neighborCount;
    thisVel += (perceivedCenter - thisPos) * rule1Scale;
    thisVel += cohesion * rule3Scale;
  }
  thisVel += separation * rule2Scale;
  return thisVel;
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
  // Compute a new velocity based on pos and vel1
  // Clamp the speed
  // Record the new velocity into vel2. Question: why NOT vel1?
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 newVel = computeVelocityChange(N, index, pos, vel1);
  if (glm::length(newVel) > maxSpeed) {
    newVel = (newVel / glm::length(newVel)) * maxSpeed;
  }
  vel2[index] = newVel;
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {
  // TODO-2.1
  // - Label each boid with the index of its grid cell.
  // - Set up a parallel array of integer indices as pointers to the actual
  //   boid data in pos and vel1/vel2
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  glm::vec3 gridSpacePos = thisPos - gridMin;
  //float sideLength = gridResolution / inverseCellWidth;
  // want to find out the cell index that i am in and label it
  int gridIdx = gridIndex3Dto1D(glm::floor(gridSpacePos.x * inverseCellWidth),
                                glm::floor(gridSpacePos.y * inverseCellWidth),
                                glm::floor(gridSpacePos.z * inverseCellWidth),
                                gridResolution);
  gridIndices[index] = gridIdx;
  // store the boid indices
  indices[index] = index;
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
  // TODO-2.1
  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }
  int gridIdx = particleGridIndices[index];
  // update start indices
  if (index == 0) {
    gridCellStartIndices[gridIdx] = 0;
  } 
  else if (particleGridIndices[index] != particleGridIndices[index - 1]) {
    gridCellStartIndices[gridIdx] = index;
  }
  // update end indices
  if (index == N - 1) {
    gridCellEndIndices[gridIdx] = N - 1;
  }
  else if (particleGridIndices[index] != particleGridIndices[index + 1]) {
    gridCellEndIndices[gridIdx] = index;
  }
  // the grids that don't have boids should have value -1
}

__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int* gridCellStartIndices, int* gridCellEndIndices,
  int* particleArrayIndices, int* particleGridIndices,
  glm::vec3* pos, glm::vec3* vel1, glm::vec3* vel2) {
  // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  glm::vec3 thisVel = vel1[index];
  float sideLength = gridResolution * cellWidth;

  int searchGridStart[8];
  int searchGridEnd[8];
  for (int i = 0; i < 8; i++) {
    searchGridStart[i] = -1;
    searchGridEnd[i] = -1;
  }
  glm::vec3 roundPos = glm::vec3(glm::round(thisPos.x / cellWidth) * cellWidth,
    glm::round(thisPos.y / cellWidth) * cellWidth,
    glm::round(thisPos.z / cellWidth) * cellWidth);

  int arrI = 0;
  for (int i = -1; i <= 1; i += 2) {
    for (int j = -1; j <= 1; j += 2) {
      for (int k = -1; k <= 1; k += 2) {
        glm::vec3 offset = glm::vec3(i * 0.5 * cellWidth,
                                     j * 0.5 * cellWidth,
                                     k * 0.5 * cellWidth);
        glm::vec3 gridSpacePos = roundPos - gridMin + offset;
        //glm::vec3 offset = glm::vec3(i * 0.5 * cellWidth);
        //glm::vec3 gridSpacePos = roundPos - gridMin + offset;
        if (gridSpacePos.x > sideLength || gridSpacePos.x < 0.0f ||
          gridSpacePos.y > sideLength || gridSpacePos.y < 0.0f ||
          gridSpacePos.z > sideLength || gridSpacePos.z < 0.0f) {
          continue;
        }
        int tempGridIdx = gridIndex3Dto1D(glm::floor(gridSpacePos.x * inverseCellWidth),
                                          glm::floor(gridSpacePos.y * inverseCellWidth),
                                          glm::floor(gridSpacePos.z * inverseCellWidth),
                                          gridResolution);
        if (gridCellStartIndices[tempGridIdx] == -1) {
          continue;
        }
        else {
          searchGridStart[arrI] = gridCellStartIndices[tempGridIdx];
          searchGridEnd[arrI] = gridCellEndIndices[tempGridIdx];
          arrI++;
        }
      }
    }
  }

  // iterate and update velocity
  glm::vec3 perceivedCenter = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 separation = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 cohesion = glm::vec3(0.0f, 0.0f, 0.0f);
  int neighborCount = 0;

  for (int i = 0; i < 8; i++) {
    if (i < 0 || i >= 8) {
      break;
    }
    for (int j = searchGridStart[i]; j <= searchGridEnd[i]; j++) {
      if (particleArrayIndices[j] == index) {
        continue;
      }
      glm::vec3 bPos = pos[particleArrayIndices[j]];
      glm::vec3 bVel = vel1[particleArrayIndices[j]];
      float distance = glm::length(thisPos - bPos);

      // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
      if (distance < rule1Distance) {
        perceivedCenter += bPos;
        neighborCount++;
      }
      // Rule 2: boids try to stay a distance d away from each other
      if (distance < rule2Distance) {
        separation -= (bPos - thisPos);
      }
      // Rule 3: boids try to match the speed of surrounding boids
      if (distance < rule3Distance) {
        cohesion += bVel;
      }
    }
  }

  if (neighborCount > 0) {
    perceivedCenter /= neighborCount;
    cohesion /= neighborCount;
    thisVel += (perceivedCenter - thisPos) * rule1Scale;
    thisVel += cohesion * rule3Scale;
  }
  thisVel += separation * rule2Scale;

  if (glm::length(thisVel) > maxSpeed) {
    thisVel = (thisVel / glm::length(thisVel)) * maxSpeed;
  }
  vel2[index] = thisVel;

}



__global__ void kernUpdateVelNeighborSearchScattered27(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int* gridCellStartIndices, int* gridCellEndIndices,
  int* particleArrayIndices, int* particleGridIndices,
  glm::vec3* pos, glm::vec3* vel1, glm::vec3* vel2) {
  // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  glm::vec3 thisVel = vel1[index];
  float sideLength = gridResolution * cellWidth;

  int searchGridStart[27];
  int searchGridEnd[27];
  for (int i = 0; i < 8; i++) {
    searchGridStart[i] = -1;
    searchGridEnd[i] = -1;
  }
  glm::vec3 gridSpacePos = thisPos - gridMin;
  glm::vec3 midPos = glm::vec3(glm::floor(gridSpacePos.x / cellWidth) * cellWidth + 0.5*cellWidth,
    glm::floor(gridSpacePos.y / cellWidth) * cellWidth + 0.5 * cellWidth,
    glm::floor(gridSpacePos.z / cellWidth) * cellWidth + 0.5 * cellWidth);

  int arrI = 0;
  for (int i = -1; i <= 1; i += 1) {
    for (int j = -1; j <= 1; j += 1) {
      for (int k = -1; k <= 1; k += 1) {
        glm::vec3 offset = glm::vec3(i * cellWidth,
          j * cellWidth,
          k * cellWidth);
        glm::vec3 newPos = midPos + offset;
        if (newPos.x > sideLength || newPos.x < 0.0f ||
          newPos.y > sideLength || newPos.y < 0.0f ||
          newPos.z > sideLength || newPos.z < 0.0f) {
          continue;
        }
        int tempGridIdx = gridIndex3Dto1D(glm::floor(newPos.x * inverseCellWidth),
          glm::floor(newPos.y * inverseCellWidth),
          glm::floor(newPos.z * inverseCellWidth),
          gridResolution);
        if (gridCellStartIndices[tempGridIdx] == -1) {
          continue;
        }
        else {
          searchGridStart[arrI] = gridCellStartIndices[tempGridIdx];
          searchGridEnd[arrI] = gridCellEndIndices[tempGridIdx];
          arrI++;
        }
      }
    }
  }

  // iterate and update velocity
  glm::vec3 perceivedCenter = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 separation = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 cohesion = glm::vec3(0.0f, 0.0f, 0.0f);
  int neighborCount = 0;

  for (int i = 0; i < 27; i++) {
    if (i < 0 || i >= 27) {
      break;
    }
    for (int j = searchGridStart[i]; j <= searchGridEnd[i]; j++) {
      if (particleArrayIndices[j] == index) {
        continue;
      }
      glm::vec3 bPos = pos[particleArrayIndices[j]];
      glm::vec3 bVel = vel1[particleArrayIndices[j]];
      float distance = glm::length(thisPos - bPos);

      // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
      if (distance < rule1Distance) {
        perceivedCenter += bPos;
        neighborCount++;
      }
      // Rule 2: boids try to stay a distance d away from each other
      if (distance < rule2Distance) {
        separation -= (bPos - thisPos);
      }
      // Rule 3: boids try to match the speed of surrounding boids
      if (distance < rule3Distance) {
        cohesion += bVel;
      }
    }
  }

  if (neighborCount > 0) {
    perceivedCenter /= neighborCount;
    cohesion /= neighborCount;
    thisVel += (perceivedCenter - thisPos) * rule1Scale;
    thisVel += cohesion * rule3Scale;
  }
  thisVel += separation * rule2Scale;

  if (glm::length(thisVel) > maxSpeed) {
    thisVel = (thisVel / glm::length(thisVel)) * maxSpeed;
  }
  vel2[index] = thisVel;

}





__global__ void kernUpdateVelNeighborSearchCoherent27(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int* gridCellStartIndices, int* gridCellEndIndices,
  glm::vec3* pos, glm::vec3* vel1, glm::vec3* vel2) {
  // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  glm::vec3 thisVel = vel1[index];
  float sideLength = gridResolution * cellWidth;

  int searchGridStart[27];
  int searchGridEnd[27];
  for (int i = 0; i < 8; i++) {
    searchGridStart[i] = -1;
    searchGridEnd[i] = -1;
  }
  glm::vec3 gridSpacePos = thisPos - gridMin;
  glm::vec3 midPos = glm::vec3(glm::floor(gridSpacePos.x / cellWidth) * cellWidth + 0.5 * cellWidth,
    glm::floor(gridSpacePos.y / cellWidth) * cellWidth + 0.5 * cellWidth,
    glm::floor(gridSpacePos.z / cellWidth) * cellWidth + 0.5 * cellWidth);

  int arrI = 0;
  for (int i = -1; i <= 1; i += 1) {
    for (int j = -1; j <= 1; j += 1) {
      for (int k = -1; k <= 1; k += 1) {
        glm::vec3 offset = glm::vec3(i * cellWidth,
          j * cellWidth,
          k * cellWidth);
        glm::vec3 newPos = midPos + offset;
        if (newPos.x > sideLength || newPos.x < 0.0f ||
          newPos.y > sideLength || newPos.y < 0.0f ||
          newPos.z > sideLength || newPos.z < 0.0f) {
          continue;
        }
        int tempGridIdx = gridIndex3Dto1D(glm::floor(newPos.x * inverseCellWidth),
          glm::floor(newPos.y * inverseCellWidth),
          glm::floor(newPos.z * inverseCellWidth),
          gridResolution);
        if (gridCellStartIndices[tempGridIdx] == -1) {
          continue;
        }
        else {
          searchGridStart[arrI] = gridCellStartIndices[tempGridIdx];
          searchGridEnd[arrI] = gridCellEndIndices[tempGridIdx];
          arrI++;
        }
      }
    }
  }

  // iterate and update velocity
  glm::vec3 perceivedCenter = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 separation = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 cohesion = glm::vec3(0.0f, 0.0f, 0.0f);
  int neighborCount = 0;

  for (int i = 0; i < 27; i++) {
    if (i < 0 || i >= 27) {
      break;
    }
    for (int j = searchGridStart[i]; j <= searchGridEnd[i]; j++) {
      if (j == index) {
        continue;
      }
      glm::vec3 bPos = pos[j];
      glm::vec3 bVel = vel1[j];
      float distance = glm::length(thisPos - bPos);

      // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
      if (distance < rule1Distance) {
        perceivedCenter += bPos;
        neighborCount++;
      }
      // Rule 2: boids try to stay a distance d away from each other
      if (distance < rule2Distance) {
        separation -= (bPos - thisPos);
      }
      // Rule 3: boids try to match the speed of surrounding boids
      if (distance < rule3Distance) {
        cohesion += bVel;
      }
    }
  }

  if (neighborCount > 0) {
    perceivedCenter /= neighborCount;
    cohesion /= neighborCount;
    thisVel += (perceivedCenter - thisPos) * rule1Scale;
    thisVel += cohesion * rule3Scale;
  }
  thisVel += separation * rule2Scale;

  if (glm::length(thisVel) > maxSpeed) {
    thisVel = (thisVel / glm::length(thisVel)) * maxSpeed;
  }
  vel2[index] = thisVel;

}






// -----------------------------------------------------------------------------
__global__ void kernCopyVel(int N, glm::vec3* buffer1, glm::vec3* buffer2) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }
  buffer1[index] = buffer2[index];
}

__global__ void kernCopyInt(int N, int* buffer1, int* buffer2) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }
  buffer1[index] = buffer2[index];
}

__global__ void kernCopyDummy(int N, glm::vec3* buffer1, glm::vec3* dummy, int* arrayIndices) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }
  buffer1[index] = dummy[arrayIndices[index]];
}

// -----------------------------------------------------------------------------


__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
  // This should expect gridCellStartIndices and gridCellEndIndices to refer
  // directly to pos and vel1.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  //   DIFFERENCE: For best results, consider what order the cells should be
  //   checked in to maximize the memory benefits of reordering the boids data.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  glm::vec3 thisVel = vel1[index];
  float sideLength = gridResolution * cellWidth;

  int searchGridStart[8];
  int searchGridEnd[8];
  for (int i = 0; i < 8; i++) {
    searchGridStart[i] = -1;
    searchGridEnd[i] = -1;
  }
  glm::vec3 roundPos = glm::vec3(glm::round(thisPos.x / cellWidth) * cellWidth,
    glm::round(thisPos.y / cellWidth) * cellWidth,
    glm::round(thisPos.z / cellWidth) * cellWidth);

  int arrI = 0;
  for (int i = -1; i <= 1; i += 2) {
    for (int j = -1; j <= 1; j += 2) {
      for (int k = -1; k <= 1; k += 2) {
        glm::vec3 offset = glm::vec3(i * 0.5 * cellWidth,
          j * 0.5 * cellWidth,
          k * 0.5 * cellWidth);
        glm::vec3 gridSpacePos = roundPos - gridMin + offset;
        if (gridSpacePos.x > sideLength || gridSpacePos.x < 0.0f ||
          gridSpacePos.y > sideLength || gridSpacePos.y < 0.0f ||
          gridSpacePos.z > sideLength || gridSpacePos.z < 0.0f) {
          continue;
        }
        int tempGridIdx = gridIndex3Dto1D(glm::floor(gridSpacePos.x * inverseCellWidth),
          glm::floor(gridSpacePos.y * inverseCellWidth),
          glm::floor(gridSpacePos.z * inverseCellWidth),
          gridResolution);
        if (gridCellStartIndices[tempGridIdx] == -1) {
          continue;
        }
        else {
          searchGridStart[arrI] = gridCellStartIndices[tempGridIdx];
          searchGridEnd[arrI] = gridCellEndIndices[tempGridIdx];
          arrI++;
        }
      }
    }
  }

  // iterate and update velocity
  glm::vec3 perceivedCenter = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 separation = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 cohesion = glm::vec3(0.0f, 0.0f, 0.0f);
  int neighborCount = 0;

  for (int i = 0; (i < 8 && i != -1); i++) {
    for (int j = searchGridStart[i]; j <= searchGridEnd[i]; j++) {
      if (j == index) {
        continue;
      }
      glm::vec3 bPos = pos[j];
      glm::vec3 bVel = vel1[j];
      float distance = glm::length(thisPos - bPos);

      // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
      if (distance < rule1Distance) {
        perceivedCenter += bPos;
        neighborCount++;
      }
      // Rule 2: boids try to stay a distance d away from each other
      if (distance < rule2Distance) {
        separation -= (bPos - thisPos);
      }
      // Rule 3: boids try to match the speed of surrounding boids
      if (distance < rule3Distance) {
        cohesion += bVel;
      }
    }
  }

  if (neighborCount > 0) {
    perceivedCenter /= neighborCount;
    cohesion /= neighborCount;
    thisVel += (perceivedCenter - thisPos) * rule1Scale;
    thisVel += cohesion * rule3Scale;
  }
  thisVel += separation * rule2Scale;

  if (glm::length(thisVel) > maxSpeed) {
    thisVel = (thisVel / glm::length(thisVel)) * maxSpeed;
  }
  vel2[index] = thisVel;
}


/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
  // TODO-1.2 - use the kernels you wrote to step the simulation forward in time.
  // TODO-1.2 ping-pong the velocity buffers
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  kernUpdateVelocityBruteForce <<<fullBlocksPerGrid, blockSize>>> (numObjects, dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelocityBruteForce failed!");

  kernUpdatePos << <fullBlocksPerGrid, blockSize >> > (numObjects, dt, dev_pos, dev_vel2);
  checkCUDAErrorWithLine("kernUpdatePos failed!");

  // ping-pong
  kernCopyVel << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernCopy Failed!");

  
}

void Boids::stepSimulationScatteredGrid(float dt) {
  // TODO-2.1
  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernComputeIndices <<<fullBlocksPerGrid, blockSize>>> (numObjects, gridSideCount,
   gridMinimum, gridInverseCellWidth, dev_pos, dev_particleArrayIndices, dev_particleGridIndices);
  checkCUDAErrorWithLine("kernComputeIndices failed!");

  // use thrust to sort

  thrust::device_ptr<int> dev_thrust_gridIndices(dev_particleGridIndices);
  thrust::device_ptr<int> dev_thrust_boidIndices(dev_particleArrayIndices);
  thrust::sort_by_key(dev_thrust_gridIndices, dev_thrust_gridIndices + numObjects, dev_thrust_boidIndices);

  // preset start and end indices to -1 before updating them
  dim3 blocksBasedOnCellCount((gridCellCount + blockSize - 1) / blockSize);
  kernResetIntBuffer <<<blocksBasedOnCellCount, blockSize>>> (gridCellCount, dev_gridCellStartIndices, -1);
  checkCUDAErrorWithLine("kernResetIntBuffer failed!");
  kernResetIntBuffer << <blocksBasedOnCellCount, blockSize >> > (gridCellCount, dev_gridCellEndIndices, -1);
  checkCUDAErrorWithLine("kernResetIntBuffer failed!");

  // update start end indices
  kernIdentifyCellStartEnd <<<fullBlocksPerGrid, blockSize >>> (numObjects, dev_particleGridIndices, 
   dev_gridCellStartIndices, dev_gridCellEndIndices);
  checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");

   //update velocity
  kernUpdateVelNeighborSearchScattered27 << <fullBlocksPerGrid, blockSize >> > (
    numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, gridCellWidth, dev_gridCellStartIndices, 
    dev_gridCellEndIndices, dev_particleArrayIndices, dev_particleGridIndices, dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelNeighborSearchScattered failed!");

  // update position and ping-pong
  kernUpdatePos << <fullBlocksPerGrid, blockSize >> > (numObjects, dt, dev_pos, dev_vel2);
  checkCUDAErrorWithLine("kernUpdatePos failed!");

  // ping pong
  kernCopyVel << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernCopy Failed!");


}

void Boids::stepSimulationCoherentGrid(float dt) {
  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:
  // - Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernComputeIndices << <fullBlocksPerGrid, blockSize >> > (numObjects, gridSideCount,
    gridMinimum, gridInverseCellWidth, dev_pos, dev_particleArrayIndices, dev_particleGridIndices);
  checkCUDAErrorWithLine("kernComputeIndices failed!");

   //setup dummy arrays
  kernCopyVel << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_dummyPos, dev_pos);
  checkCUDAErrorWithLine("kernCopy Failed!");
  kernCopyVel << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_dummyVel1, dev_vel1);
  checkCUDAErrorWithLine("kernCopy Failed!");


  // use thrust to sort
  thrust::device_ptr<int> dev_thrust_gridIndices(dev_particleGridIndices);
  thrust::device_ptr<int> dev_thrust_boidIndices(dev_particleArrayIndices);
  thrust::sort_by_key(dev_thrust_gridIndices, dev_thrust_gridIndices + numObjects, dev_thrust_boidIndices);

  kernCopyDummy << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_pos, dev_dummyPos, dev_particleArrayIndices);
  checkCUDAErrorWithLine("kernCopyDummy Failed!");
  kernCopyDummy << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_vel1, dev_dummyVel1, dev_particleArrayIndices);
  checkCUDAErrorWithLine("kernCopyDummy Failed!");

  

  // preset start and end indices to -1 before updating them
  dim3 blocksBasedOnCellCount((gridCellCount + blockSize - 1) / blockSize);
  kernResetIntBuffer << <blocksBasedOnCellCount, blockSize >> > (gridCellCount, dev_gridCellStartIndices, -1);
  checkCUDAErrorWithLine("kernResetIntBuffer failed!");
  kernResetIntBuffer << <blocksBasedOnCellCount, blockSize >> > (gridCellCount, dev_gridCellEndIndices, -1);
  checkCUDAErrorWithLine("kernResetIntBuffer failed!");

  // update start end indices
  kernIdentifyCellStartEnd << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_particleGridIndices,
    dev_gridCellStartIndices, dev_gridCellEndIndices);
  checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");

  //update velocity
  kernUpdateVelNeighborSearchCoherent27 << <fullBlocksPerGrid, blockSize >> > (
    numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, gridCellWidth, dev_gridCellStartIndices,
    dev_gridCellEndIndices, dev_pos, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernUpdateVelNeighborSearchCoherent failed!");

  // update position and ping-pong
  kernUpdatePos << <fullBlocksPerGrid, blockSize >> > (numObjects, dt, dev_pos, dev_vel2);
  checkCUDAErrorWithLine("kernUpdatePos failed!");

  // ping pong
  kernCopyVel << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_vel1, dev_vel2);
  checkCUDAErrorWithLine("kernCopy Failed!");
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  // TODO-2.1 TODO-2.3 - Free any additional buffers here.
  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_particleGridIndices);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);

  cudaFree(dev_dummyPos);
  cudaFree(dev_dummyVel1);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int* dev_dummyKeys;
  int *dev_intValues;
  glm::vec3* dev_newValues;
  int N = 10;

  std::unique_ptr<int[]>intKeys{ new int[N] };
  std::unique_ptr<int[]>dummyKeys{ new int[N] };
  std::unique_ptr<int[]>intValues{ new int[N] };
  std::unique_ptr<glm::vec3[]>newValues{ new glm::vec3[N] };

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  dummyKeys[0] = 0; 
  dummyKeys[1] = 1;
  dummyKeys[2] = 0;
  dummyKeys[3] = 3;
  dummyKeys[4] = 0;
  dummyKeys[5] = 2;
  dummyKeys[6] = 2;
  dummyKeys[7] = 0;
  dummyKeys[8] = 5;
  dummyKeys[9] = 6;

  newValues[0] = glm::vec3(0.0, 0.0, 0.0);
  newValues[1] = glm::vec3(1.0, 0.0, 0.0);
  newValues[2] = glm::vec3(2.0, 0.0, 0.0);
  newValues[3] = glm::vec3(3.0, 0.0, 0.0);
  newValues[4] = glm::vec3(4.0, 0.0, 0.0);
  newValues[5] = glm::vec3(5.0, 0.0, 0.0);
  newValues[6] = glm::vec3(6.0, 0.0, 0.0);
  newValues[7] = glm::vec3(7.0, 0.0, 0.0);
  newValues[8] = glm::vec3(8.0, 0.0, 0.0);
  newValues[9] = glm::vec3(9.0, 0.0, 0.0);

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_dummyKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_dummyKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  cudaMalloc((void**)&dev_newValues, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_newValues failed!");
  


  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i];
    std::cout << " newValue: " << newValues[i].x << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_dummyKeys, dummyKeys.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_newValues, newValues.get(), sizeof(glm::vec3) * N, cudaMemcpyHostToDevice);

  /*for (int i = 0; i < N; i++) {
    dev_dummyKeys[i] = dev_intKeys[i];
  }*/
  //dev_dummyKeys = dev_intKeys;
  //dev_dummyKeys[0] = 0;

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  //thrust::device_ptr<int> dev_thrust_dummykeys(dev_dummyKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  thrust::device_ptr<glm::vec3> dev_thrust_newvalues(dev_newValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);
  //thrust::sort_by_key(dev_thrust_dummykeys, dev_thrust_dummykeys + N, dev_thrust_newvalues);


  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(dummyKeys.get(), dev_dummyKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(newValues.get(), dev_newValues, sizeof(glm::vec3) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i];
    std::cout << " newValue: " << newValues[i].x << std::endl;
  }

  // cleanup
  cudaFree(dev_intKeys);
  cudaFree(dev_dummyKeys);
  cudaFree(dev_intValues);
  cudaFree(dev_newValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
