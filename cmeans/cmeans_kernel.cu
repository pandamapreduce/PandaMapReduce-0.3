#include <stdio.h>
#include <stdlib.h>
#include <cutil.h>
#include <cmeans.h>
#include <cmeanscu.h>
#include <float.h>

__global__ void UpdateClusterCentersGPU(const float* oldClusters, const float* events, float* newClusters, float* distanceMatrix){

	float membershipValue;//, denominator;
	
	__shared__ float numerators[NUM_DIMENSIONS*NUM_THREADS];
	__shared__ float myClusters[NUM_DIMENSIONS*NUM_CLUSTERS];

    // Sum of the memberships computed by each thread
    // The sum of all of these denominators together is effectively the size of the cluster
	__shared__ float denominators[NUM_THREADS];
		
    int tid = threadIdx.x;

    // initialize numerators and denominators to 0
    denominators[tid] = 0;
    for(int j = tid; j < NUM_DIMENSIONS*NUM_THREADS; j+=NUM_THREADS){
        numerators[j] = 0;
    }
    // Copy cluster centers into shared memory
    for(int j = tid; j < NUM_DIMENSIONS*NUM_CLUSTERS; j+=NUM_THREADS){
        myClusters[j] = oldClusters[j];
    }

    __syncthreads();
     
    // Compute new membership value for each event
    // Add its contribution to the numerator and denominator for that thread
    for(int j = tid; j < NUM_EVENTS; j+=NUM_THREADS){
          
        membershipValue = MembershipValueGPU(myClusters, events, blockIdx.x, j, distanceMatrix);
        #if FUZZINESS == 2 
            // This is much faster than the pow function
            membershipValue = membershipValue*membershipValue;
        #else
            membershipValue = pow(membershipValue,FUZZINESS);
        #endif

        #pragma unroll 6 // Prevent compiler from unrolling this loop too much, eats up too many registers
        for(int k = 0; k < NUM_DIMENSIONS; k++){
            numerators[tid*NUM_DIMENSIONS + k] += events[k*NUM_EVENTS + j]*membershipValue;
            //numerators[tid*NUM_DIMENSIONS + k] += events[j*NUM_DIMENSIONS + k]*membershipValue;
        }
        denominators[tid] += membershipValue;
    } 

    __syncthreads();
	  
    // Sum up the numerators, one for each dimension	
    // (reducing all rows of numerators into the first row)
    // One thread per dimension
	if(tid < NUM_DIMENSIONS){
        for(int j = 1; j < NUM_THREADS; j++){
            numerators[tid] += numerators[j*NUM_DIMENSIONS+tid];
        }  
        //numerators[tid] = numerators[tid] / (float)NUM_THREADS;
	}

    // Sum up the denominator, one for this block
    if(tid == 0){
      for(int j = 1; j < NUM_THREADS; j++){
        denominators[0] += denominators[j];
      }
      //denominators[0] = denominators[0]/NUM_THREADS;
    }
    __syncthreads();

	// Set the new center for this block	
    if(tid < NUM_DIMENSIONS) {
        newClusters[blockIdx.x*NUM_DIMENSIONS + tid] = numerators[tid]/denominators[0];
    }  
}

__global__ void ComputeDistanceMatrix(const float* clusters, const float* events, float* matrix) {
    
    // copy centers into shared memory	
    __shared__ float myClusters[NUM_DIMENSIONS*NUM_CLUSTERS];
    for(int j = threadIdx.x; j < NUM_DIMENSIONS*NUM_CLUSTERS; j+=NUM_THREADS_MATRIX){
        myClusters[j] = clusters[j];
    }

    /*
    int cluster = 0;
    int dim = 0;
    for(int j = threadIdx.x; j < NUM_DIMENSIONS*NUM_CLUSTERS; j+= NUM_THREADS) {
        cluster = j / NUM_DIMENSIONS;
        dim = j % NUM_DIMENSIONS;
        myClusters[dim*NUM_CLUSTERS+cluster] = clusters[cluster*NUM_DIMENSIONS+dim];
    }
    */
    __syncthreads();

    // For each event
    // Note: global memory writes should be coalesced, but the event data access in CalculateDistanceGPU isn't
    for(int i=threadIdx.x; i < NUM_EVENTS; i+= NUM_THREADS_MATRIX) {
        matrix[blockIdx.x*NUM_EVENTS+i] = CalculateDistanceGPU(myClusters,events,blockIdx.x,i);
    }
}


__device__ float MembershipValueGPU(const float* clusters, const float* events, int clusterIndex, int eventIndex, const float* distanceMatrix){
	float myClustDist = 0;
    // Compute the distance from this event to the given cluster
	//myClustDist = CalculateDistanceGPU(clusters, events, clusterIndex, eventIndex);
    myClustDist = distanceMatrix[clusterIndex*NUM_EVENTS+eventIndex];
	
	float sum =0;
	float otherClustDist;
	for(int j = 0; j< NUM_CLUSTERS; j++){
		//otherClustDist = CalculateDistanceGPU(clusters, events, j, eventIndex);
        otherClustDist = distanceMatrix[j*NUM_EVENTS+eventIndex];

		if(otherClustDist < 1e-10)
			return 0.0;
		sum += pow((myClustDist/otherClustDist),(2/(FUZZINESS-1)));
		
	}
	return 1.0/sum;
}

__device__ float MembershipValueDist(const float* clusters, const float* events, int clusterIndex, int eventIndex, float distance, float* distanceMatrix){
	float sum =0;
	float otherClustDist;
	for(int j = 0; j< NUM_CLUSTERS; j++){
		//otherClustDist = CalculateDistanceGPU(clusters, events, j, eventIndex);	
        otherClustDist = distanceMatrix[j*NUM_EVENTS+eventIndex];
		if(otherClustDist < 1e-10)
			return 0.0;
		sum += pow((float)(distance/otherClustDist),float(2/(FUZZINESS-1)));
	}
	return 1/sum;
}

__device__ float CalculateDistanceGPU(const float* clusters, const float* events, int clusterIndex, int eventIndex){

	float sum = 0;
	float tmp;
#if DISTANCE_MEASURE == 0 // Euclidean
    #pragma unroll 6 // Prevent compiler from unrolling this loop, eats up too many registers
    for(int i = 0; i < NUM_DIMENSIONS; i++){
        tmp = events[i*NUM_EVENTS+eventIndex] - clusters[clusterIndex*NUM_DIMENSIONS +i];
        //tmp = events[eventIndex*NUM_DIMENSIONS + i] - clusters[clusterIndex*NUM_DIMENSIONS + i];
        sum += tmp*tmp;
    }
    sum = sqrt(sum);
#endif
#if DISTANCE_MEASURE == 1 // Absolute value
    #pragma unroll 6 // Prevent compiler from unrolling this loop, eats up too many registers
    for(int i = 0; i < NUM_DIMENSIONS; i++){
        tmp = events[i*NUM_EVENTS+eventIndex] - clusters[clusterIndex*NUM_DIMENSIONS +i];
        //tmp = events[eventIndex*NUM_DIMENSIONS + i] - clusters[clusterIndex*NUM_DIMENSIONS + i];
        sum += abs(tmp);
    }
#endif
#if DISTANCE_MEASURE == 2 // Maximum distance 
    #pragma unroll 6 // Prevent compiler from unrolling this loop, eats up too many registers
    for(int i = 0; i < NUM_DIMENSIONS; i++){
        tmp = abs(events[i*NUM_EVENTS + eventIndex] - clusters[clusterIndex*NUM_DIMENSIONS + i]);
        //tmp = abs(events[eventIndex*NUM_DIMENSIONS + i] - clusters[clusterIndex*NUM_DIMENSIONS + i]);
        if(tmp > sum)
            sum = tmp;
    }
#endif
	return sum;
}

__device__ float CalculateQII(const float* events, const float* clusters, int cluster_index_I, float* EI, float* numMem, float* distanceMatrix){
	EI[threadIdx.x] = 0;
	numMem[threadIdx.x] = 0;
	
	for(int i = threadIdx.x; i < NUM_EVENTS; i+=Q_THREADS){
        float distance = distanceMatrix[cluster_index_I*NUM_EVENTS+i];
        //float distance = CalculateDistanceGPU(clusters,events, cluster_index_I, i);
		float memVal = MembershipValueDist(clusters, events,  cluster_index_I, i, distance, distanceMatrix);
		
		if(memVal > MEMBER_THRESH){
			EI[threadIdx.x] += memVal*memVal * distance*distance;
			numMem[threadIdx.x]++;
		}
	}
	
	__syncthreads();
	
	if(threadIdx.x == 0){
		for(int i = 1; i < Q_THREADS; i++){
			EI[0] += EI[i];
			numMem[0] += numMem[i];
		}
	}
	__syncthreads();

	return ((((float)K1) * numMem[0]) - (((float)K2) * EI[0]) - (((float)K3) * NUM_DIMENSIONS));
}

__device__ float CalculateQIJ(const float* events, const float* clusters, int cluster_index_I, int cluster_index_J, float * EI, float * EJ, float *numMem, float* distanceMatrix){
	EI[threadIdx.x] = 0;
	EJ[threadIdx.x] = 0;
	numMem[threadIdx.x] = 0;
	
	for(int i = threadIdx.x; i < NUM_EVENTS; i+=Q_THREADS){
            float distance = distanceMatrix[cluster_index_I*NUM_EVENTS+i];
			//float distance = CalculateDistanceGPU(clusters, events, cluster_index_I, i+threadIdx.x);
			float memValI = MembershipValueDist(clusters, events, cluster_index_I, i, distance, distanceMatrix);
		
			if(memValI > MEMBER_THRESH){
				EI[threadIdx.x] += memValI*memValI * distance*distance;
			}
			
            distance = distanceMatrix[cluster_index_J*NUM_EVENTS+i];
			//distance = CalculateDistanceGPU(clusters, events, cluster_index_J, i);
			float memValJ = MembershipValueDist(clusters, events, cluster_index_J, i, distance, distanceMatrix);
			if(memValJ > MEMBER_THRESH){
				EJ[threadIdx.x] += memValJ*memValJ * distance*distance;
			}
			if(memValI > MEMBER_THRESH && memValJ > MEMBER_THRESH){
				numMem[threadIdx.x]++;
			}
	
	}
	__syncthreads();

	if(threadIdx.x == 0){
		for(int i = 1; i < Q_THREADS; i++){
			EI[0] += EI[i];
			EJ[0] += EJ[i];
			numMem[0] += numMem[i];
		}
	}

	__syncthreads();
	float EB = (EI[0] > EJ[0]) ? EI[0] : EJ[0];
	return ((-1*((float)K1)*numMem[0]) + ((float)K2)*EB);
}

__global__ void CalculateQMatrixGPUUpgrade(const float* events, const float* clusters, float* matrix, float* distanceMatrix){
	__shared__ float myClusters[NUM_CLUSTERS*NUM_DIMENSIONS];
	__shared__ float EI[Q_THREADS];
	__shared__ float EJ[Q_THREADS];
	__shared__ float numMem[Q_THREADS];
	for(int j = 0; j < NUM_CLUSTERS*NUM_DIMENSIONS; j+= Q_THREADS){
		if(j+threadIdx.x < NUM_CLUSTERS*NUM_DIMENSIONS){
			myClusters[j+threadIdx.x] = clusters[j+threadIdx.x];

		}
	}
	__syncthreads();
	if(blockIdx.x == blockIdx.y){
		matrix[blockIdx.x*NUM_CLUSTERS + blockIdx.y ] = CalculateQII(events, myClusters, blockIdx.x, EI, numMem, distanceMatrix);
	}
	else{
		matrix[blockIdx.x*NUM_CLUSTERS + blockIdx.y] = CalculateQIJ(events, myClusters, blockIdx.x, blockIdx.y, EI, EJ, numMem, distanceMatrix);
	}	
}
