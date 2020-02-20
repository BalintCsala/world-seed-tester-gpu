#include <stdint.h>
#include <stdio.h>
#include <string>
#include <iostream>
#include <fstream>
#include <sstream>
#include <stdint.h>
#include <vector>
#define long int64_t
// TODO: Fix speed calculation when these are different numbers.
#define INPUT_BLOCK_SIZE (2 << 20)
#define WORK_UNIT_SIZE (2 << 20)
#define CHECK_GPU_ERR(code) gpuAssert((code), __FILE__, __LINE__)

#ifndef CHUNK_X
#define CHUNK_X 0
#endif
#ifndef CHUNK_Y
#define CHUNK_Y 0
#endif

#define TREE_ATTEMPTS 12

#define RANDOM_MASK (1ULL << 48) - 1
#define setSeed(rand, val) ((rand) = ((val) ^ 0x5DEECE66DLL) & ((1LL << 48) - 1))
#define advance(rand, multiplier, addend) ((rand) = ((rand) * (multiplier) + (addend)) & (RANDOM_MASK))
#define advance_1(rand) advance(rand, 0x5DEECE66DLL, 0xBLL)
#define advance_16(rand) advance(rand, 0x6DC260740241LL, 0xD0352014D90LL)
#define advance_3760(rand) advance(rand, 0x8C35C76B80C1LL, 0xD7F102F24F30LL)

__host__ __device__ int next(long *rand, int bits) {
	*rand = (*rand * 0x5DEECE66DLL + 0xBLL) & ((1LL << 48) - 1);
	return (int)(*rand >> (48 - bits));
}
__host__ __device__ long nextLong(long *rand) {
	return ((long)next(rand, 32) << 32) + next(rand, 32);
}
__host__ __device__ int nextIntBound(long *rand, int bound) {
	return (int)((bound * (long)next(rand, 31)) >> 31);
}

inline void gpuAssert(cudaError_t code, const char* file, int line) {
    if (code != cudaSuccess) {
        fprintf(stderr, "GPUassert: %s (code %d) %s %d\n", cudaGetErrorString(code), code, file, line);
        exit(code);
    }
}

struct Chunk {
	int x, y;
	__host__ __device__ bool operator==(const Chunk &rhs) {
		return this->x == rhs.x && this->y == rhs.y;
	}
};

struct Tree {
	int x, y, h;
	__host__ __device__ bool operator==(const Tree &rhs) {
		return this->x == rhs.x && this->y == rhs.y && this->h == rhs.h;
	}
	__host__ __device__ bool operator>=(const Tree &rhs) {
		return this->x >= rhs.x && this->y >= rhs.y && this->h >= rhs.h;
	}
	__host__ __device__ bool operator<=(const Tree &rhs) {
		return this->x <= rhs.x && this->y <= rhs.y && this->h <= rhs.h;
	}
};

__constant__ Chunk chunks[] = {{3, 4}};

__device__ bool checkTree(int chunkIndex, Tree tree) {
	switch(chunkIndex) {
		case 0:
			if (tree == Tree{ 4,  0, 6}) return true;
			else if (tree == Tree{13, 14, 4}) return true;
			else if (tree == Tree{13,  3, 5}) return true;
			else if (tree == Tree{12, 11, 6}) return true;
			else if (tree == Tree{10,  2, 4}) return true;
		break;
		default:
		break;
	}
	return false;
}

// TODO: Allow trees to have a range of possible coordinates.
__global__ void process(long* seeds, long offset) {
	long index = offset + blockIdx.x * blockDim.x + threadIdx.x;
	long seed = seeds[index];
	long rand;
	for(int c = 0; c < sizeof(chunks) / sizeof(Chunk); c++) {
		setSeed(rand, seed);
		long chunkSeed = (chunks[c].x + CHUNK_X) * (nextLong(&rand) / 2LL * 2LL + 1LL) + (chunks[c].y + CHUNK_Y) * (nextLong(&rand) / 2LL * 2LL + 1LL) ^ seed;
		setSeed(rand, chunkSeed);
		advance_3760(rand);
		int found = 0;
		for (int attempt = 0; attempt < TREE_ATTEMPTS; attempt++) {
			Tree tree = {nextIntBound(&rand, 16), nextIntBound(&rand, 16), nextIntBound(&rand, 3) + 4};
			if (checkTree(c, tree)) {
				advance_16(rand);
				found++;
			};
		}
		if (found == 5) {
			printf("Seed: %lld.\n", seed);
		}
	}
}
//TODO: Fix timing. Using a cudaEvent_t multiple times in a loop doesn't work properly(?). Also figure out proper synchronization calls.
int main(void) {
	// Allocate RAM for input
	long *input = (long *)malloc(sizeof(long) * INPUT_BLOCK_SIZE);
	// Open File
	std::ifstream ifs ("input.txt");
	if (ifs.fail()) {
		std::cout << "ERROR::IFSTREAM::FAIL" << std::endl;
		return -1;
	}
	// Allocate VRAM for input
	long *seeds;
	CHECK_GPU_ERR(cudaMallocManaged((long **)&seeds, sizeof(long) * INPUT_BLOCK_SIZE));
	// Load Input Block
	// TODO: Fix issue where the last iteration will recheck seeds from the previous
	// iteration if the number of inputs is not evenly divisible by WORK_UNIT_SIZE
	// Currently "fixed" by setting all remaining seeds to 0.
	// clock_t startTime = clock();
	// clock_t lastIteration = clock();
	cudaEvent_t readStart, readStop, processStart, processStop, memcpyStart, memcpyStop;
	cudaEventCreate(&readStart);
	cudaEventCreate(&readStop);
	cudaEventCreate(&processStart);
	cudaEventCreate(&processStop);
	cudaEventCreate(&memcpyStart);
	cudaEventCreate(&memcpyStop);
	std::string line;
	float time;
	while(std::getline(ifs, line)) {
		cudaEventRecord(readStart, 0);
		for (long i = 0; i < INPUT_BLOCK_SIZE; i++) {
			if (ifs >> line) {
				long val = std::atoll(line.c_str());
				input[i] = val;
			} else {
				input[i] = 0;
			}
		}
		cudaEventRecord(readStop, 0);
		cudaEventSynchronize(readStop);
		cudaEventElapsedTime(&time, readStart, readStop);
		printf("Read: %f\n", time);
		// Copy to VRAM
		cudaEventRecord(memcpyStart, 0);
		CHECK_GPU_ERR(cudaMemcpy(seeds, input, sizeof(long) * INPUT_BLOCK_SIZE, cudaMemcpyHostToDevice));
		cudaEventRecord(memcpyStop, 0);
		cudaEventSynchronize(memcpyStop);
		cudaEventElapsedTime(&time, memcpyStart, memcpyStop);
		printf("Memcpy: %f\n", time);
		for(int offset = 0; offset < INPUT_BLOCK_SIZE; offset += WORK_UNIT_SIZE) {
			cudaEventRecord(processStart, 0);
			// Process input
			process<<<WORK_UNIT_SIZE / 256, 256>>>(seeds, offset);
			cudaDeviceSynchronize();
			cudaEventRecord(processStop, 0);
			cudaEventSynchronize(processStop);
			cudaEventElapsedTime(&time, processStart, processStop);
			printf("Process: %f\n", time);

			// double iterationTime = (double)(clock() - lastIteration) / CLOCKS_PER_SEC;
			// double timeElapsed = (double)(clock() - startTime) / CLOCKS_PER_SEC;
			// lastIteration = clock();
			// double speed = (double)WORK_UNIT_SIZE / (double)iterationTime / 1000000.0;
			// printf("Uptime: %.1fs. Speed: %.2fm/s.\n", timeElapsed, speed);
		}
	}
	cudaEventDestroy(readStart);
	cudaEventDestroy(readStop);
	cudaEventDestroy(processStart);
	cudaEventDestroy(processStop);
	cudaFree(seeds);
	ifs.close();
	return 0;
}