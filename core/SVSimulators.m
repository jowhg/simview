#import "SVCore.h"
#import "SVPrivate.h"
#import <dlfcn.h>
#import <libproc.h>
#import <sqlite3.h>
#import <sys/sysctl.h>

/// The Xcode whose simulators to use, the way xcrun picks it: $DEVELOPER_DIR, else the one chosen with
/// `xcode-select -s` (/var/db/xcode_select_link). The Command Line Tools have no simulators, so when that is
/// what is selected, fall back to /Applications/Xcode.app, then to any /Applications/Xcode*.app.
static NSString *SVDeveloperDir(void) {
  NSFileManager *files = NSFileManager.defaultManager;
  BOOL (^isXcode)(NSString *) = ^BOOL(NSString *dir) {
    return dir.length > 0 && [files fileExistsAtPath:[dir stringByAppendingPathComponent:@"Platforms/iPhoneSimulator.platform"]];
  };
  NSString *fromEnv = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if ([fromEnv hasSuffix:@".app"]) fromEnv = [fromEnv stringByAppendingPathComponent:@"Contents/Developer"];
  if (isXcode(fromEnv)) return fromEnv;
  NSString *selected = [[files destinationOfSymbolicLinkAtPath:@"/var/db/xcode_select_link" error:nil] stringByStandardizingPath];
  if (isXcode(selected)) return selected;
  if (isXcode(@"/Applications/Xcode.app/Contents/Developer")) return @"/Applications/Xcode.app/Contents/Developer";
  for (NSString *name in [[files contentsOfDirectoryAtPath:@"/Applications" error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
    if (![name hasPrefix:@"Xcode"] || ![name hasSuffix:@".app"]) continue;
    NSString *dir = [NSString stringWithFormat:@"/Applications/%@/Contents/Developer", name];
    if (isXcode(dir)) return dir;
  }
  return @"/Applications/Xcode.app/Contents/Developer";
}

id SVServiceContext(void) {
  static id context;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
    context = [(id<SVSimPrivate>)NSClassFromString(@"SimServiceContext")
        sharedServiceContextForDeveloperDir:SVDeveloperDir() error:nil];
  });
  return context;
}

@implementation SVSimulatorInfo

- (instancetype)initWithDevice:(id<SVSimPrivate>)device {
  if (!(self = [super init])) return nil;
  _device = device;
  _udid = [[device UDID] UUIDString];
  _name = [device name] ?: @"?";
  _state = [device stateString] ?: @"Unknown";
  _booted = [_state isEqualToString:@"Booted"];
  _runtimeName = [(id<SVSimPrivate>)[device runtime] name] ?: @"";
  id<SVSimPrivate> type = [device deviceType];
  _chromeIdentifier = [type chromeIdentifier];
  _productFamily = [type productFamily] ?: @"";
  NSError *availability = nil;
  _available = [device respondsToSelector:@selector(isAvailableWithError:)] ? [device isAvailableWithError:&availability] : YES;
  if (!_available) _unavailableReason = availability.localizedFailureReason ?: availability.localizedDescription;
  CGSize pixels = [type mainScreenSize];
  float scale = [type mainScreenScale];
  _screenPoints = scale > 0 ? CGSizeMake(pixels.width / scale, pixels.height / scale) : pixels;
  NSString *resources = [[type bundlePath] stringByAppendingPathComponent:@"Contents/Resources"];
  NSString *mask = [NSDictionary dictionaryWithContentsOfFile:[resources stringByAppendingPathComponent:@"profile.plist"]][@"framebufferMask"];
  NSString *maskPath = mask ? [resources stringByAppendingPathComponent:[mask stringByAppendingPathExtension:@"pdf"]] : nil;
  _screenMaskPath = [[NSFileManager defaultManager] fileExistsAtPath:maskPath ?: @""] ? maskPath : nil;
  return self;
}

@end

@implementation SVSimulators

+ (NSArray<SVSimulatorInfo *> *)all {
  id<SVSimPrivate> set = [SVServiceContext() defaultDeviceSetWithError:nil];
  NSMutableArray *simulators = [NSMutableArray array];
  for (id device in [set devices]) [simulators addObject:[[SVSimulatorInfo alloc] initWithDevice:device]];
  [simulators sortUsingComparator:^NSComparisonResult(SVSimulatorInfo *a, SVSimulatorInfo *b) {
    return [a.name localizedStandardCompare:b.name];
  }];
  return simulators;
}

/// The UDID in a launchd_sim's arguments (".../CoreSimulator/Devices/<UDID>/data/...").
static NSString *SVUDIDOfLaunchdSim(pid_t pid) {
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t size = 0;
  if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) return nil;
  NSMutableData *buffer = [NSMutableData dataWithLength:size];
  if (sysctl(mib, 3, buffer.mutableBytes, &size, NULL, 0) != 0) return nil;
  const char *needle = "/Devices/";
  const char *found = memmem(buffer.bytes, size, needle, strlen(needle));
  if (!found || found + strlen(needle) + 36 > (const char *)buffer.bytes + size) return nil;
  return [[NSString alloc] initWithBytes:found + strlen(needle) length:36 encoding:NSASCIIStringEncoding];
}

+ (NSDictionary<NSString *, NSNumber *> *)memoryFootprintByUDID {
  int capacity = proc_listallpids(NULL, 0) + 64;
  pid_t *pids = calloc(capacity, sizeof(pid_t));
  int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));

  NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *children = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSNumber *, NSString *> *roots = [NSMutableDictionary dictionary];
  for (int i = 0; i < count; i++) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) continue;
    NSNumber *parent = @(info.pbi_ppid);
    if (!children[parent]) children[parent] = [NSMutableArray array];
    [children[parent] addObject:@(pids[i])];
    if (strncmp(info.pbi_comm, "launchd_sim", MAXCOMLEN) == 0) {
      NSString *udid = SVUDIDOfLaunchdSim(pids[i]);
      if (udid) roots[@(pids[i])] = udid;
    }
  }
  free(pids);

  NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
  [roots enumerateKeysAndObjectsUsingBlock:^(NSNumber *root, NSString *udid, BOOL *stop) {
    unsigned long long total = 0;
    NSMutableArray<NSNumber *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
      NSNumber *pid = stack.lastObject;
      [stack removeLastObject];
      struct rusage_info_v4 usage;
      if (proc_pid_rusage(pid.intValue, RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0) total += usage.ri_phys_footprint;
      [stack addObjectsFromArray:children[pid] ?: @[]];
    }
    result[udid] = @(total);
  }];
  return result;
}

+ (NSInteger)allowPasteOnDevice:(id<SVSimPrivate>)device {
  if (![device respondsToSelector:@selector(installedAppsWithError:)] || ![device respondsToSelector:@selector(dataPath)]) return -1;
  NSDictionary *apps = [device installedAppsWithError:nil];
  NSString *path = [[device dataPath] stringByAppendingPathComponent:@"Library/TCC/TCC.db"];
  if (apps.count == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return -1;

  sqlite3 *db = NULL;
  if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
    sqlite3_close(db);
    return -1;
  }
  sqlite3_busy_timeout(db, 2000);  // the simulator's tccd shares the database
  // Allowed (2) by the user (2). Rows already allowed are left alone, so after the first call this writes nothing.
  static const char *sql =
      "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags) "
      "VALUES ('kTCCServicePasteboard', ?1, 0, 2, 2, 2, 0) "
      "ON CONFLICT (service, client, client_type, indirect_object_identifier) DO UPDATE "
      "SET auth_value = 2, auth_reason = 2, last_modified = CAST(strftime('%s', 'now') AS INTEGER) WHERE auth_value != 2";
  sqlite3_stmt *statement = NULL;
  NSInteger changed = -1;
  if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) == SQLITE_OK) {
    if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) == SQLITE_OK) {
      changed = 0;
      for (NSString *bundleID in apps) {
        sqlite3_bind_text(statement, 1, bundleID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(statement) == SQLITE_DONE) changed += sqlite3_changes(db);
        sqlite3_reset(statement);
      }
      sqlite3_finalize(statement);
    }
    if (changed < 0 || sqlite3_exec(db, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
      sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
      changed = -1;
    }
  }
  sqlite3_close(db);
  return changed;
}

@end
