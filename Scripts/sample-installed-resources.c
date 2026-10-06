// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <uuid/uuid.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    errno = 0;
    long candidate = strtol(argv[1], &end, 10);
    if (errno || !end || *end || candidate <= 0 || candidate > INT_MAX) return 2;
    int pid = (int)candidate;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid,path,sizeof(path)) <= 0 || strcmp(path,"/Applications/Aether.app/Contents/MacOS/Aether")) {
        fputs("Expected the formal installed Aether process.\n",stderr); return 1;
    }
    struct rusage_info_v4 r = {0};
    if (proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t *)&r) != 0) { perror("proc_pid_rusage"); return 1; }
    char uuid[37];
    uuid_unparse(r.ri_uuid,uuid);
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return 1;
    printf("{\"pid\":%d,\"executable_uuid\":\"%s\",\"start_ticks\":%" PRIu64 ",\"user_ticks\":%" PRIu64 ",\"system_ticks\":%" PRIu64
           ",\"resident_bytes\":%" PRIu64 ",\"footprint_bytes\":%" PRIu64 ",\"idle_wakeups\":%" PRIu64
           ",\"interrupt_wakeups\":%" PRIu64 ",\"disk_read_bytes\":%" PRIu64 ",\"disk_write_bytes\":%" PRIu64
           ",\"timebase_numer\":%u,\"timebase_denom\":%u}\n",
           pid,uuid,r.ri_proc_start_abstime,r.ri_user_time,r.ri_system_time,r.ri_resident_size,r.ri_phys_footprint,
           r.ri_pkg_idle_wkups,r.ri_interrupt_wkups,r.ri_diskio_bytesread,r.ri_diskio_byteswritten,timebase.numer,timebase.denom);
    return 0;
}
