// procstat: one line per process: pid, cumulative CPU ns, phys_footprint bytes, executable path.
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
int main(void) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  int n = proc_listallpids(NULL, 0) + 64;
  pid_t *pids = calloc(n, sizeof(pid_t));
  n = proc_listallpids(pids, n * sizeof(pid_t));
  for (int i = 0; i < n; i++) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pids[i], path, sizeof path) <= 0) continue;
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) {
      printf("%d\t-1\t-1\t%s\n", pids[i], path);
      continue;
    }
    unsigned long long cpu = (ri.ri_user_time + ri.ri_system_time) * tb.numer / tb.denom;  // mach units -> ns
    printf("%d\t%llu\t%llu\t%s\n", pids[i], cpu, ri.ri_phys_footprint, path);
  }
  return 0;
}
