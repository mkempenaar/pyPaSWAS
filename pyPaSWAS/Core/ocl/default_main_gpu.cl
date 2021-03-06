/** maximum X per block (used in dimensions for blocks and amount of shared memory */
#define SHARED_X ${SHARED_X}
/** maximum Y per block (used in dimensions for blocks and amount of shared memory */
#define SHARED_Y ${SHARED_Y}

/** kernel contains a for-loop in which the score is calculated. */
#define DIAGONAL SHARED_X + SHARED_Y

/** amount of blocks across the X axis */
#define XdivSHARED_X (X/SHARED_X)
/** amount of blocks across the Y axis */
#define YdivSHARED_Y (Y/SHARED_Y)

/** character used to fill the sequence if length < X */
#define FILL_CHARACTER '\0'
#define FILL_SCORE -1E10

/** Set init for affine gap matrices */
#define AFFINE_GAP_INIT -1E10f

/** this value is used to allocate enough memory to store the starting points */
#define MAXIMUM_NUMBER_STARTING_POINTS (NUMBER_SEQUENCES*NUMBER_TARGETS*1000)

/**** Other definitions ****/

/** bit mask to get the negative value of a float, or to keep it negative */
#define SIGN_BIT_MASK 0x80000000

/* Scorings matrix for each thread block */
typedef struct {
	float value[SHARED_X][SHARED_Y];
}  LocalMatrix;

/* Scorings matrix for each sequence alignment */
typedef struct {
	LocalMatrix matrix[XdivSHARED_X][YdivSHARED_Y];
} ScoringsMatrix;

/* Scorings matrix for entire application */
typedef struct {
	ScoringsMatrix metaMatrix[NUMBER_SEQUENCES][NUMBER_TARGETS];
} GlobalMatrix;

typedef struct {
    float value[XdivSHARED_X][YdivSHARED_Y];
} BlockMaxima;

typedef struct {
    BlockMaxima blockMaxima[NUMBER_SEQUENCES][NUMBER_TARGETS];
} GlobalMaxima;

typedef struct {
	unsigned char value[SHARED_X][SHARED_Y];
} LocalDirection;

typedef struct {
	LocalDirection localDirection[XdivSHARED_X][YdivSHARED_Y];
} Direction;

typedef struct {
	Direction direction[NUMBER_SEQUENCES][NUMBER_TARGETS];
} GlobalDirection;

typedef struct {
	unsigned int sequence;
	unsigned int target;
	unsigned int blockX;
	unsigned int blockY;
	unsigned int valueX;
	unsigned int valueY;
	float score;
	float maxScore;
	float posScore;
} StartingPoint;

typedef struct {
	StartingPoint startingPoint[MAXIMUM_NUMBER_STARTING_POINTS];
} StartingPoints;

__kernel void calculateScore(
		__global GlobalMatrix *matrix, 
		unsigned int x, 
		unsigned int y, 
		unsigned int numberOfBlocks,
		__global char *sequences, 
		__global char *targets, 
		__global GlobalMaxima *globalMaxima, 
		__global GlobalDirection *globalDirection) {
	
	/**
     * shared memory block for calculations. It requires
     * extra (+1 in both directions) space to hold
     * Neighboring cells
     */
	__local float s_matrix[SHARED_X+1][SHARED_Y+1];
    /**
     * shared memory block for storing the maximum value of each neighboring cell.
     * Careful: the s_maxima[SHARED_X][SHARED_Y] does not contain the maximum value
     * after the calculation loop! This value is determined at the end of this
     * function.
     */
	__local float s_maxima[SHARED_X][SHARED_Y];

    // calculate indices:
    //unsigned int yDIVnumSeq = (blockIdx.y/NUMBER_SEQUENCES);
    // 1 is in y-direction and 0 is in x-direction
    unsigned int blockx = x - get_group_id(1)/NUMBER_TARGETS;//yDIVnumSeq;
    unsigned int blocky = y + get_group_id(1)/NUMBER_TARGETS;//yDIVnumSeq;
    unsigned int tIDx = get_local_id(0);
    unsigned int tIDy = get_local_id(1);
    unsigned int bIDx = get_group_id(0);
    unsigned int bIDy = get_group_id(1)%NUMBER_TARGETS;///numberOfBlocks;
    unsigned char direction = NO_DIRECTION;

    // indices of the current characters in both sequences.
    int seqIndex1 = tIDx + bIDx * X + blockx * SHARED_X;
    int seqIndex2 = tIDy + bIDy * Y + blocky * SHARED_Y;


    /* the next block is to get the maximum value from surrounding blocks. This maximum values is compared to the
     * first element in the shared score matrix s_matrix.
     */
    float maxPrev = 0.0f;
    if (!tIDx && !tIDy) {
        if (blockx && blocky) {
            maxPrev = fmax(fmax(globalMaxima->blockMaxima[bIDx][bIDy].value[blockx-1][blocky-1], globalMaxima->blockMaxima[bIDx][bIDy].value[blockx-1][blocky]), globalMaxima->blockMaxima[bIDx][bIDy].value[blockx][blocky-1]);
        }
        else if (blockx) {
            maxPrev = globalMaxima->blockMaxima[bIDx][bIDy].value[blockx-1][blocky];
        }
        else if (blocky) {
            maxPrev = globalMaxima->blockMaxima[bIDx][bIDy].value[blockx][blocky-1];
        }
    }
    // local scorings variables:
    float currentScore, ulS, lS, uS;
    float innerScore = 0.0f;
    /**
     * tXM1 and tYM1 are to store the current value of the thread Index. tIDx and tIDy are
     * both increased with 1 later on.
     */
    unsigned int tXM1 = tIDx;
    unsigned int tYM1 = tIDy;

    // shared location for the parts of the 2 sequences, for faster retrieval later on:
    __local char s_seq1[SHARED_X];
    __local char s_seq2[SHARED_Y];

    // copy sequence data to shared memory (shared is much faster than global)
    if (!tIDy)
        s_seq1[tIDx] = sequences[seqIndex1];
    if (!tIDx)
        s_seq2[tIDy] = targets[seqIndex2];

    // set both matrices to zero
    s_matrix[tIDx][tIDy] = 0.0f;
    s_maxima[tIDx][tIDy] = 0.0f;

    if (tIDx == SHARED_X-1  && ! tIDy)
        s_matrix[SHARED_X][0] = 0.0f;
    if (tIDy == SHARED_Y-1  && ! tIDx)
        s_matrix[0][SHARED_Y] = 0.0f;

    /**** sync barrier ****/
    s_matrix[tIDx][tIDy] = 0.0f;
    barrier(CLK_LOCAL_MEM_FENCE);

    // initialize outer parts of the matrix:
    if (!tIDx || !tIDy) {
        if (tIDx == SHARED_X-1)
            s_matrix[tIDx+1][tIDy] = 0.0f;
        if (tIDy == SHARED_Y-1)
            s_matrix[tIDx][tIDy+1] = 0.0f;
        if (blockx && !tIDx) {
            s_matrix[0][tIDy+1] = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy];
        }
        if (blocky && !tIDy) {
            s_matrix[tIDx+1][0] = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx][SHARED_Y-1];
        }
        if (blockx && blocky && !tIDx && !tIDy){
            s_matrix[0][0] = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky-1].value[SHARED_X-1][SHARED_Y-1];
        }
    }
    // set inner score (aka sequence match/mismatch score):
    char charS1 = s_seq1[tIDx];
    char charS2 = s_seq2[tIDy];
    
 	innerScore = charS1 == FILL_CHARACTER || charS2 == FILL_CHARACTER ? FILL_SCORE : scoringsMatrix[charS1-characterOffset][charS2-characterOffset];

    // transpose the index
    ++tIDx;
    ++tIDy;
    // set shared matrix to zero (starting point!)
    s_matrix[tIDx][tIDy] = 0.0f;


    // wait until all elements have been copied to the shared memory block
        /**** sync barrier ****/
    barrier(CLK_LOCAL_MEM_FENCE);

    currentScore = 0.0f;

    for (int i=0; i < DIAGONAL; ++i) {
        if (i == tXM1+ tYM1) {
            // calculate only when there are two valid characters
            // this is necessary when the two sequences are not of equal length
            // this is the SW-scoring of the cell:

          ulS = s_matrix[tXM1][tYM1] + innerScore;
          lS = s_matrix[tXM1][tIDy] + gapScore;
          uS = s_matrix[tIDx][tYM1] + gapScore;

            if (currentScore < lS) { // score comes from left
                currentScore = lS;
                direction = LEFT_DIRECTION;
            }
            if (currentScore < uS) { // score comes from above
                currentScore = uS;
                direction = UPPER_DIRECTION;
            }
            if (currentScore < ulS) { // score comes from upper left
                currentScore = ulS;
                direction = UPPER_LEFT_DIRECTION;
            }
            s_matrix[tIDx][tIDy] = innerScore == FILL_SCORE ? 0.0 : currentScore; // copy score to matrix
        }

        else if (i-1 == tXM1 + tYM1 ){
                // use this to find fmax
            if (i==1) {
                s_maxima[0][0] = fmax(maxPrev, currentScore);
            }
            else if (!tXM1 && tYM1) {
                s_maxima[0][tYM1] = fmax(s_maxima[0][tYM1-1], currentScore);
            }
            else if (!tYM1 && tXM1) {
                s_maxima[tXM1][0] = fmax(s_maxima[tXM1-1][0], currentScore);
            }
            else if (tXM1 && tYM1 ){
                s_maxima[tXM1][tYM1] = fmax(s_maxima[tXM1-1][tYM1], fmax(s_maxima[tXM1][tYM1-1], currentScore));
            }
        }
        // wait until all threads have calculated their new score
            /**** sync barrier ****/
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    // copy end score to the scorings matrix:
    (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tXM1][tYM1] = s_matrix[tIDx][tIDy];
    (*globalDirection).direction[bIDx][bIDy].localDirection[blockx][blocky].value[tXM1][tYM1] = direction;

    if (tIDx==SHARED_X && tIDy==SHARED_Y)
        globalMaxima->blockMaxima[bIDx][bIDy].value[blockx][blocky] = fmax(currentScore, fmax(s_maxima[SHARED_X-2][SHARED_Y-1], s_maxima[SHARED_X-1][SHARED_Y-2]));

    // wait until all threads have copied their score:
        /**** sync barrier ****/
    barrier(CLK_LOCAL_MEM_FENCE);
}

__kernel void calculateScoreAffineGap(
		__global GlobalMatrix *matrix, 
		__global GlobalMatrix *matrix_i, 
		__global GlobalMatrix *matrix_j, 
		unsigned int x, 
		unsigned int y, 
		unsigned int numberOfBlocks,
		__global char *sequences, 
		__global char *targets, 
		__global GlobalMaxima *globalMaxima, 
		__global GlobalDirection *globalDirection) {
	
	/**
     * shared memory block for calculations. It requires
     * extra (+1 in both directions) space to hold
     * Neighboring cells
     */
	__local float s_matrix[SHARED_X+1][SHARED_Y+1];
	__local float s_matrix_i[SHARED_X+1][SHARED_Y+1];
	__local float s_matrix_j[SHARED_X+1][SHARED_Y+1];
    /**
     * shared memory block for storing the maximum value of each neighboring cell.
     * Careful: the s_maxima[SHARED_X][SHARED_Y] does not contain the maximum value
     * after the calculation loop! This value is determined at the end of this
     * function.
     */
	__local float s_maxima[SHARED_X][SHARED_Y];

    // calculate indices:
    //unsigned int yDIVnumSeq = (blockIdx.y/NUMBER_SEQUENCES);
    // 1 is in y-direction and 0 is in x-direction
    unsigned int blockx = x - get_group_id(1)/NUMBER_TARGETS;//yDIVnumSeq;
    unsigned int blocky = y + get_group_id(1)/NUMBER_TARGETS;//yDIVnumSeq;
    unsigned int tIDx = get_local_id(0);
    unsigned int tIDy = get_local_id(1);
    unsigned int bIDx = get_group_id(0);
    unsigned int bIDy = get_group_id(1)%NUMBER_TARGETS;///numberOfBlocks;
    unsigned char direction = NO_DIRECTION;
    unsigned char direction_i = NO_DIRECTION;
    unsigned char direction_j = NO_DIRECTION;

    // indices of the current characters in both sequences.
    int seqIndex1 = tIDx + bIDx * X + blockx * SHARED_X;
    int seqIndex2 = tIDy + bIDy * Y + blocky * SHARED_Y;


    /* the next block is to get the maximum value from surrounding blocks. This maximum values is compared to the
     * first element in the shared score matrix s_matrix.
     */
    float maxPrev = 0.0f;
    if (!tIDx && !tIDy) {
        if (blockx && blocky) {
            maxPrev = fmax(fmax(globalMaxima->blockMaxima[bIDx][bIDy].value[blockx-1][blocky-1], globalMaxima->blockMaxima[bIDx][bIDy].value[blockx-1][blocky]), globalMaxima->blockMaxima[bIDx][bIDy].value[blockx][blocky-1]);
        }
        else if (blockx) {
            maxPrev = globalMaxima->blockMaxima[bIDx][bIDy].value[blockx-1][blocky];
        }
        else if (blocky) {
            maxPrev = globalMaxima->blockMaxima[bIDx][bIDy].value[blockx][blocky-1];
        }
    }
    // local scorings variables:
    float currentScore,currentScore_i, currentScore_j, m_M, m_I, m_J;
    float innerScore = 0.0f;
    /**
     * tXM1 and tYM1 are to store the current value of the thread Index. tIDx and tIDy are
     * both increased with 1 later on.
     */
    unsigned int tXM1 = tIDx;
    unsigned int tYM1 = tIDy;

    // shared location for the parts of the 2 sequences, for faster retrieval later on:
    __local char s_seq1[SHARED_X];
    __local char s_seq2[SHARED_Y];

    // copy sequence data to shared memory (shared is much faster than global)
    if (!tIDy)
        s_seq1[tIDx] = sequences[seqIndex1];
    if (!tIDx)
        s_seq2[tIDy] = targets[seqIndex2];

    // init matrices
    s_matrix[tIDx][tIDy] = 0.0f;
    s_matrix_i[tIDx][tIDy] = AFFINE_GAP_INIT;
    s_matrix_j[tIDx][tIDy] = AFFINE_GAP_INIT;
    s_maxima[tIDx][tIDy] = 0.0f;

    if (tIDx == SHARED_X-1  && ! tIDy){
        s_matrix[SHARED_X][0] = 0.0f;
        s_matrix_i[SHARED_X][0] = AFFINE_GAP_INIT;
        s_matrix_j[SHARED_X][0] = AFFINE_GAP_INIT;
    }
    if (tIDy == SHARED_Y-1  && ! tIDx) {
        s_matrix[0][SHARED_Y] = 0.0f;
        s_matrix_i[0][SHARED_Y] = AFFINE_GAP_INIT;
        s_matrix_j[0][SHARED_Y] = AFFINE_GAP_INIT;
    }

    /**** sync barrier ****/
    s_matrix[tIDx][tIDy] = 0.0f;
    barrier(CLK_LOCAL_MEM_FENCE);

    // initialize outer parts of the matrix:
    if (!tIDx || !tIDy) {
        if (tIDx == SHARED_X-1) {
            s_matrix[tIDx+1][tIDy] = 0.0f;
            s_matrix_i[tIDx+1][tIDy] = AFFINE_GAP_INIT;
            s_matrix_j[tIDx+1][tIDy] = AFFINE_GAP_INIT;
        }
        if (tIDy == SHARED_Y-1) {
            s_matrix[tIDx][tIDy+1] = 0.0f;
            s_matrix_i[tIDx][tIDy+1] = AFFINE_GAP_INIT;
            s_matrix_j[tIDx][tIDy+1] = AFFINE_GAP_INIT;
        }
        if (blockx && !tIDx) {
            s_matrix[0][tIDy+1] = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy];
            s_matrix_i[0][tIDy+1] = (*matrix_i).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy];
            s_matrix_j[0][tIDy+1] = (*matrix_j).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy];
        }
        if (blocky && !tIDy) {
            s_matrix[tIDx+1][0] = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx][SHARED_Y-1];
            s_matrix_i[tIDx+1][0] = (*matrix_i).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx][SHARED_Y-1];
            s_matrix_j[tIDx+1][0] = (*matrix_j).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx][SHARED_Y-1];
        }
        if (blockx && blocky && !tIDx && !tIDy){
            s_matrix[0][0] = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky-1].value[SHARED_X-1][SHARED_Y-1];
            s_matrix_i[0][0] = (*matrix_i).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky-1].value[SHARED_X-1][SHARED_Y-1];
            s_matrix_j[0][0] = (*matrix_j).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky-1].value[SHARED_X-1][SHARED_Y-1];
        }
    }
    // set inner score (aka sequence match/mismatch score):
    char charS1 = s_seq1[tIDx];
    char charS2 = s_seq2[tIDy];
    
 	innerScore = charS1 == FILL_CHARACTER || charS2 == FILL_CHARACTER ? FILL_SCORE : scoringsMatrix[charS1-characterOffset][charS2-characterOffset];

    // transpose the index
    ++tIDx;
    ++tIDy;
    // set shared matrix to zero (starting point!)
    s_matrix[tIDx][tIDy] = 0.0f;
    s_matrix_i[tIDx][tIDy] = AFFINE_GAP_INIT;
    s_matrix_j[tIDx][tIDy] = AFFINE_GAP_INIT;


    // wait until all elements have been copied to the shared memory block
        /**** sync barrier ****/
    barrier(CLK_LOCAL_MEM_FENCE);


    for (int i=0; i < DIAGONAL; ++i) {
        if (i == tXM1+ tYM1) {
            currentScore = 0.0f;
        	m_M = s_matrix[tXM1][tYM1]+innerScore;
        	m_I = s_matrix_i[tXM1][tYM1]+innerScore;
        	m_J = s_matrix_j[tXM1][tYM1]+innerScore;

        	if (currentScore < m_I) { // score comes from I matrix (gap in x)
        		currentScore = m_I;
        		direction = A_DIRECTION | MAIN_MATRIX;
        	}
        	if (currentScore < m_J) { // score comes from J matrix (gap in y)
        		currentScore = m_J;
        		direction = A_DIRECTION | MAIN_MATRIX;
        	}
        	if (currentScore < m_M) { // score comes from m matrix (match)
        		currentScore = m_M;
        		direction = A_DIRECTION | MAIN_MATRIX;
        	}
        	s_matrix[tIDx][tIDy] = innerScore == FILL_SCORE ? 0.0 : currentScore; // copy score to matrix

        	// now do I matrix:
        	currentScore_i = AFFINE_GAP_INIT;
        	m_M = gapScore + gapExtension + s_matrix[tIDx][tYM1];
			m_I = gapExtension + s_matrix_i[tIDx][tYM1];

			if (currentScore_i < m_I) { // score comes from I matrix (gap in x)
        		currentScore_i = m_I;
        		direction_i = B_DIRECTION | I_MATRIX;
        	}
        	if (currentScore_i < m_M) { // score comes from m matrix (match)
        		currentScore_i = m_M;
        		direction_i= B_DIRECTION | I_MATRIX;
        	}
        	s_matrix_i[tIDx][tIDy] = currentScore_i < 0 ? AFFINE_GAP_INIT : currentScore_i; // copy score to matrix

        	// now do J matrix:
        	currentScore_j = AFFINE_GAP_INIT;
        	m_M = gapScore + gapExtension + s_matrix[tXM1][tIDy];
			m_J = gapExtension + s_matrix_j[tXM1][tIDy];

        	if (currentScore_j < m_J) { // score comes from J matrix (gap in y)
        		currentScore_j = m_J;
        		direction_j = C_DIRECTION | J_MATRIX;
        	}
        	if (currentScore_j < m_M) { // score comes from m matrix (match)
        		currentScore_j = m_M;
        		direction_j = C_DIRECTION | J_MATRIX;
        	}
        	s_matrix_j[tIDx][tIDy] = currentScore_j < 0 ? AFFINE_GAP_INIT : currentScore_j; // copy score to matrix

        	currentScore = fmax(currentScore,fmax(currentScore_i,currentScore_j));
        	if (currentScore > 0) {
				if (currentScore == s_matrix[tIDx][tIDy]) {// direction from main
					direction = direction;
				}
				else if(currentScore == s_matrix_i[tIDx][tIDy]) {// direction from I
					direction = direction_i;
				}
				else if(currentScore == s_matrix_j[tIDx][tIDy]){ // direction from J
					direction = direction_j;
				}
        	}
        }

        else if (i-1 == tXM1 + tYM1 ){
                // use this to find fmax
            if (i==1) {
                s_maxima[0][0] = fmax(maxPrev, currentScore);
            }
            else if (!tXM1 && tYM1) {
                s_maxima[0][tYM1] = fmax(s_maxima[0][tYM1-1], currentScore);
            }
            else if (!tYM1 && tXM1) {
                s_maxima[tXM1][0] = fmax(s_maxima[tXM1-1][0], currentScore);
            }
            else if (tXM1 && tYM1 ){
                s_maxima[tXM1][tYM1] = fmax(s_maxima[tXM1-1][tYM1], fmax(s_maxima[tXM1][tYM1-1], currentScore));
            }
        }
        // wait until all threads have calculated their new score
            /**** sync barrier ****/
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    // copy end score to the scorings matrix:
    (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tXM1][tYM1] = s_matrix[tIDx][tIDy];
    (*matrix_i).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tXM1][tYM1] = s_matrix_i[tIDx][tIDy];
    (*matrix_j).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tXM1][tYM1] = s_matrix_j[tIDx][tIDy];
    (*globalDirection).direction[bIDx][bIDy].localDirection[blockx][blocky].value[tXM1][tYM1] = direction;

    if (tIDx==SHARED_X && tIDy==SHARED_Y)
        globalMaxima->blockMaxima[bIDx][bIDy].value[blockx][blocky] = fmax(currentScore, fmax(s_maxima[SHARED_X-2][SHARED_Y-1], s_maxima[SHARED_X-1][SHARED_Y-2]));

    // wait until all threads have copied their score:
        /**** sync barrier ****/
    barrier(CLK_LOCAL_MEM_FENCE);
}


__kernel void traceback(
		__global GlobalMatrix *matrix, 
		unsigned int x, 
		unsigned int y, 
		unsigned int numberOfBlocks, 
		__global GlobalMaxima *globalMaxima,
		__global GlobalDirection *globalDirection, 
		volatile __global unsigned int *indexIncrement,
		__global StartingPoints *startingPoints, 
		__global float *maxPossibleScore) {

	/**
     * shared memory block for calculations. It requires
     * extra (+1 in both directions) space to hold
     * Neighboring cells
     */
	__local float s_matrix[SHARED_X+1][SHARED_Y+1];
    /**
     * shared memory for storing the maximum value of this alignment.
     */
	__local float s_maxima[1];
	__local float s_maxPossibleScore[1];

    // calculate indices:
    unsigned int yDIVnumSeq = (get_group_id(1)/NUMBER_TARGETS);
    unsigned int blockx = x - yDIVnumSeq;
    unsigned int blocky = y + yDIVnumSeq;
    unsigned int tIDx = get_local_id(0);
    unsigned int tIDy = get_local_id(1);
    unsigned int bIDx = get_group_id(0);
    unsigned int bIDy = get_group_id(1)%NUMBER_TARGETS;
    
    float value = 0.0;

    if (!tIDx && !tIDy) {
        s_maxima[0] = globalMaxima->blockMaxima[bIDx][bIDy].value[XdivSHARED_X-1][YdivSHARED_Y-1];
        s_maxPossibleScore[0] = maxPossibleScore[bIDy*NUMBER_SEQUENCES+bIDx];
    }

    barrier(CLK_LOCAL_MEM_FENCE);
    if (s_maxima[0]>= MINIMUM_SCORE) { // if the maximum score is below threshold, there is nothing to do

        s_matrix[tIDx][tIDy] = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tIDx][tIDy];

        unsigned char direction = globalDirection->direction[bIDx][bIDy].localDirection[blockx][blocky].value[tIDx][tIDy];


        // wait until all elements have been copied to the shared memory block
        /**** sync barrier ****/
        barrier(CLK_LOCAL_MEM_FENCE);

        for (int i=DIAGONAL-1; i >= 0; --i) {

            if ((i == tIDx + tIDy) && direction == UPPER_LEFT_DIRECTION && s_matrix[tIDx][tIDy] >= LOWER_LIMIT_SCORE * s_maxima[0] && s_matrix[tIDx][tIDy] >= s_maxPossibleScore[0]) {
                // found starting point!
                // reserve index:
                unsigned int index = atom_inc(&indexIncrement[0]);
                StartingPoint start;
                //__global StartingPoint *start = &(startingPoints->startingPoint[index]);
                start.sequence = bIDx;
                start.target = bIDy;
                start.blockX = blockx;
                start.blockY = blocky;
                start.valueX = tIDx;
                start.valueY = tIDy;
                start.score = s_matrix[tIDx][tIDy];
                start.maxScore = s_maxima[0];
                start.posScore = s_maxPossibleScore[0];
                startingPoints->startingPoint[index] = start;
                // mark this value:             
				s_matrix[tIDx][tIDy] = as_float(SIGN_BIT_MASK | as_int(s_matrix[tIDx][tIDy]));
               
            }
                
            barrier(CLK_LOCAL_MEM_FENCE);

            if ((i == tIDx + tIDy) && s_matrix[tIDx][tIDy] < 0 && direction == UPPER_LEFT_DIRECTION) {
                if (tIDx && tIDy){
                    value = s_matrix[tIDx-1][tIDy-1];
                    if (value == 0.0f) {
                    	direction = STOP_DIRECTION;
                    }     
                    else {
						s_matrix[tIDx-1][tIDy-1] = as_float(SIGN_BIT_MASK | as_int(value));
                    }
                        
                    	
                }
                else if (!tIDx && tIDy && blockx) {
                    value = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy-1];
                    if (value == 0.0f) {
                    	direction = STOP_DIRECTION;
                    }   
                    else {
                    	(*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy-1] = as_float(SIGN_BIT_MASK | as_int(value));
                    }
                        
                }
                else if (!tIDx && !tIDy && blockx && blocky) {
                    value = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky-1].value[SHARED_X-1][SHARED_Y-1];
                    if (value == 0.0f) {
                    	direction = STOP_DIRECTION;
                    }
                    else {
	              		(*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky-1].value[SHARED_X-1][SHARED_Y-1] = as_float(SIGN_BIT_MASK | as_int(value));
                    }
                        
                }
                else if (tIDx && !tIDy && blocky) {
                    value = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx-1][SHARED_Y-1];
                    if (value == 0.0f) {
                    	direction = STOP_DIRECTION;
                    }    
                    else {
						(*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx-1][SHARED_Y-1] = as_float(SIGN_BIT_MASK | as_int(value));
                    }
                        
                }
            }
            barrier(CLK_LOCAL_MEM_FENCE);

            if ((i == tIDx + tIDy) && s_matrix[tIDx][tIDy] < 0 && direction == UPPER_DIRECTION) {
                if (!tIDy) {
                    if (blocky) {
                        value = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx][SHARED_Y-1];
                        if (value == 0.0f) {
                        	direction = STOP_DIRECTION;
                        }
                        else {
                        	(*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx][SHARED_Y-1] = as_float(SIGN_BIT_MASK | as_int(value));
                        }
                            
                    }
                }
                else {
                    value = s_matrix[tIDx][tIDy-1];
                    if (value == 0.0f) {
                    	direction = STOP_DIRECTION;
                    }
                    else {
						s_matrix[tIDx][tIDy-1] = as_float(SIGN_BIT_MASK | as_int(value));
                    }
                        
                }
            }

            barrier(CLK_LOCAL_MEM_FENCE);
            if ((i == tIDx + tIDy) && s_matrix[tIDx][tIDy] < 0 && direction == LEFT_DIRECTION) {
                if (!tIDx){
                    if (blockx) {
                        value = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy];
                        if (value == 0.0f) {
                            direction = STOP_DIRECTION;
                        }
                        else {
							(*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy] = as_float(SIGN_BIT_MASK | as_int(value));
                        }
                            
                    }
                }
                else {
                    value = s_matrix[tIDx-1][tIDy];
                    if (value == 0.0f) {
                    	direction = STOP_DIRECTION;
                    }
                    else {
                    	s_matrix[tIDx-1][tIDy] = as_float(SIGN_BIT_MASK | as_int(value));
                    }
                        
                }
            }

            barrier(CLK_LOCAL_MEM_FENCE);

        }

        // copy end score to the scorings matrix:
        if (s_matrix[tIDx][tIDy] < 0) {
            (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tIDx][tIDy] = s_matrix[tIDx][tIDy];
            globalDirection->direction[bIDx][bIDy].localDirection[blockx][blocky].value[tIDx][tIDy] = direction;
        }
        /**** sync barrier ****/
        barrier(CLK_LOCAL_MEM_FENCE);
    }
}


__kernel void tracebackAffineGap(
		__global GlobalMatrix *matrix,
		__global GlobalMatrix *matrix_i, 
		__global GlobalMatrix *matrix_j, 		
		unsigned int x, 
		unsigned int y, 
		unsigned int numberOfBlocks, 
		__global GlobalMaxima *globalMaxima,
		__global GlobalDirection *globalDirection, 
		volatile __global unsigned int *indexIncrement,
		__global StartingPoints *startingPoints, 
		__global float *maxPossibleScore) {

	/**
     * shared memory block for calculations. It requires
     * extra (+1 in both directions) space to hold
     * Neighboring cells
     */
	__local float s_matrix[SHARED_X+1][SHARED_Y+1];
	__local float s_matrix_i[SHARED_X+1][SHARED_Y+1];
	__local float s_matrix_j[SHARED_X+1][SHARED_Y+1];
    /**
     * shared memory for storing the maximum value of this alignment.
     */
	__local float s_maxima[1];
	__local float s_maxPossibleScore[1];

    // calculate indices:
    unsigned int yDIVnumSeq = (get_group_id(1)/NUMBER_TARGETS);
    unsigned int blockx = x - yDIVnumSeq;
    unsigned int blocky = y + yDIVnumSeq;
    unsigned int tIDx = get_local_id(0);
    unsigned int tIDy = get_local_id(1);
    unsigned int bIDx = get_group_id(0);
    unsigned int bIDy = get_group_id(1)%NUMBER_TARGETS;
    
    float value = 0.0;

    if (!tIDx && !tIDy) {
        s_maxima[0] = globalMaxima->blockMaxima[bIDx][bIDy].value[XdivSHARED_X-1][YdivSHARED_Y-1];
        s_maxPossibleScore[0] = maxPossibleScore[bIDy*NUMBER_SEQUENCES+bIDx];
    }

    barrier(CLK_LOCAL_MEM_FENCE);
    if (s_maxima[0]>= MINIMUM_SCORE) { // if the maximum score is below threshold, there is nothing to do
        unsigned char direction = DIRECTION_MASK & globalDirection->direction[bIDx][bIDy].localDirection[blockx][blocky].value[tIDx][tIDy];
        unsigned char matrix_source = MATRIX_MASK & globalDirection->direction[bIDx][bIDy].localDirection[blockx][blocky].value[tIDx][tIDy];

    	s_matrix[tIDx][tIDy] = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tIDx][tIDy];
        s_matrix_i[tIDx][tIDy] = (*matrix_i).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tIDx][tIDy];
        s_matrix_j[tIDx][tIDy] = (*matrix_j).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tIDx][tIDy];


        // wait until all elements have been copied to the shared memory block
        /**** sync barrier ****/
        barrier(CLK_LOCAL_MEM_FENCE);

        for (int i=DIAGONAL-1; i >= 0; --i) {

            if ((i == tIDx + tIDy) && matrix_source == MAIN_MATRIX && s_matrix[tIDx][tIDy] >= LOWER_LIMIT_SCORE * s_maxima[0] && s_matrix[tIDx][tIDy] >= s_maxPossibleScore[0]) {
                // found starting point!
                // reserve index:
                unsigned int index = atom_inc(&indexIncrement[0]);
                StartingPoint start;
                //__global StartingPoint *start = &(startingPoints->startingPoint[index]);
                start.sequence = bIDx;
                start.target = bIDy;
                start.blockX = blockx;
                start.blockY = blocky;
                start.valueX = tIDx;
                start.valueY = tIDy;
                start.score = s_matrix[tIDx][tIDy];
                start.maxScore = s_maxima[0];
                start.posScore = s_maxPossibleScore[0];
                startingPoints->startingPoint[index] = start;
                // mark this value:             
				s_matrix[tIDx][tIDy] = as_float(SIGN_BIT_MASK | as_int(s_matrix[tIDx][tIDy]));
               
            }
                
            barrier(CLK_LOCAL_MEM_FENCE);

            if ((i == tIDx + tIDy) && (
            		(s_matrix[tIDx][tIDy] < 0 && matrix_source == MAIN_MATRIX) ||
            		(s_matrix_i[tIDx][tIDy] < 0 && s_matrix_i[tIDx][tIDy] > AFFINE_GAP_INIT && matrix_source == I_MATRIX) ||
            		(s_matrix_j[tIDx][tIDy] < 0 && s_matrix_j[tIDx][tIDy] > AFFINE_GAP_INIT && matrix_source == J_MATRIX)
					)) {
					// check which matrix to go to:
					switch (direction) {
					case A_DIRECTION : // M
						if (tIDx && tIDy){
							value = s_matrix[tIDx-1][tIDy-1];
							if (value == 0.0f)
								direction = STOP_DIRECTION;
							else
								s_matrix[tIDx-1][tIDy-1] = as_float(SIGN_BIT_MASK | as_int(value));
						}
						else if (!tIDx && tIDy && blockx) {
							value = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy-1];
							if (value == 0.0f)
								direction = STOP_DIRECTION;
							else
								(*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy-1] = as_float(SIGN_BIT_MASK | as_int(value));
						}
						else if (!tIDx && !tIDy && blockx && blocky) {
							value = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky-1].value[SHARED_X-1][SHARED_Y-1];
							if (value == 0.0f)
								direction = STOP_DIRECTION;
							else
								(*matrix).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky-1].value[SHARED_X-1][SHARED_Y-1] = as_float(SIGN_BIT_MASK | as_int(value));
						}
						else if (tIDx && !tIDy && blocky) {
							value = (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx-1][SHARED_Y-1];
							if (value == 0.0f)
								direction = STOP_DIRECTION;
							else
								(*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx-1][SHARED_Y-1] = as_float(SIGN_BIT_MASK | as_int(value));
						}

//direction = tracebackStepLeftUp(blockx, blocky, s_matrix, matrix, direction);
						break;
					case B_DIRECTION : // I
						if (!tIDy) {
							if (blocky) {
								value = (*matrix_i).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx][SHARED_Y-1];
								(*matrix_i).metaMatrix[bIDx][bIDy].matrix[blockx][blocky-1].value[tIDx][SHARED_Y-1] = as_float(SIGN_BIT_MASK | as_int(value));
							}
						}
						else {
							value = s_matrix_i[tIDx][tIDy-1];
							s_matrix_i[tIDx][tIDy-1] = as_float(SIGN_BIT_MASK | as_int(value));
						}

						//direction = tracebackStepUp(blockx, blocky, s_matrix_i, matrix_i, direction);
						break;
					case C_DIRECTION : // J
						if (!tIDx){
							if (blockx) {
								value = (*matrix_j).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy];
								(*matrix_j).metaMatrix[bIDx][bIDy].matrix[blockx-1][blocky].value[SHARED_X-1][tIDy] = as_float(SIGN_BIT_MASK | as_int(value));
							}
						}
						else {
							value = s_matrix_j[tIDx-1][tIDy];
							s_matrix_j[tIDx-1][tIDy] = as_float(SIGN_BIT_MASK | as_int(value));
						}

						//direction = tracebackStepLeft(blockx, blocky, s_matrix_j, matrix_j, direction);
						break;
						}
			}
            barrier(CLK_LOCAL_MEM_FENCE);
        }

        // copy end score to the scorings matrix:
        if (matrix_source == MAIN_MATRIX) {
            (*matrix).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tIDx][tIDy] = s_matrix[tIDx][tIDy];
            globalDirection->direction[bIDx][bIDy].localDirection[blockx][blocky].value[tIDx][tIDy] = direction;
        }
        else if (matrix_source == I_MATRIX) {
            (*matrix_i).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tIDx][tIDy] = s_matrix_i[tIDx][tIDy];
            globalDirection->direction[bIDx][bIDy].localDirection[blockx][blocky].value[tIDx][tIDy] = direction;
        }
        else if (matrix_source == J_MATRIX) {
            (*matrix_j).metaMatrix[bIDx][bIDy].matrix[blockx][blocky].value[tIDx][tIDy] = s_matrix_j[tIDx][tIDy];
            globalDirection->direction[bIDx][bIDy].localDirection[blockx][blocky].value[tIDx][tIDy] = direction;
        }
        /**** sync barrier ****/
        barrier(CLK_LOCAL_MEM_FENCE);
    }
}


