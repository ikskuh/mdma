#include "coremark.h"

static _Alignas(16) ee_u8 buffer[TOTAL_DATA_SIZE];
static core_results results;
unsigned long coremark_list_crc;
unsigned long coremark_matrix_crc;
unsigned long coremark_state_crc;

void coremark_iteration(void)
{
    ee_u16 crc = core_bench_list(&results, 1);
    results.crc = crcu16(crc, results.crc);
    crc = core_bench_list(&results, -1);
    results.crc = crcu16(crc, results.crc);
}

/* The simulator and RTL bench observe this entry after the iteration. */
void coremark_timed_end(void)
{
}

int main(void)
{
    results.seed1 = 0;
    results.seed2 = 0;
    results.seed3 = 0x66;
    results.iterations = 1;
    results.execs = ALL_ALGORITHMS_MASK;
    results.size = TOTAL_DATA_SIZE / NUM_ALGORITHMS;
    results.memblock[0] = buffer;
    results.memblock[1] = buffer;
    results.memblock[2] = buffer + results.size;
    results.memblock[3] = buffer + 2 * results.size;

    results.list = core_list_init(results.size, results.memblock[1], results.seed1);
    core_init_matrix(results.size, results.memblock[2], 0, &results.mat);
    core_init_state(results.size, results.seed1, results.memblock[3]);

    coremark_iteration();
    coremark_timed_end();
    coremark_list_crc = results.crc;
    coremark_matrix_crc = results.crcmatrix;
    coremark_state_crc = results.crcstate;
    return coremark_list_crc != 0xe714 || coremark_matrix_crc != 0x1fd7 ||
           coremark_state_crc != 0x8e3a || check_data_types() != 0;
}
