#import "SettingsManager.h"

@implementation SettingsManager

- (NSString*)settingsJSONPath {
  NSString* execPath = [[NSBundle mainBundle] executablePath];
  NSString* execDir = [execPath stringByDeletingLastPathComponent];
  NSString* path = [execDir stringByAppendingPathComponent:@"settings.json"];
  NSLog(@"[PdfWinViewer] settings.json path=%@", path);
  return path;
}

- (void)loadSettingsJSON {
  self.settingsDict = [NSMutableDictionary new];
  NSString* path = [self settingsJSONPath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSLog(@"[PdfWinViewer] settings.json not found");
    return;
  }
  NSData* data = [NSData dataWithContentsOfFile:path];
  if (!data) {
    NSLog(@"[PdfWinViewer] settings.json read failed");
    return;
  }
  NSError* err = nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (err || ![json isKindOfClass:[NSDictionary class]]) {
    NSLog(@"[PdfWinViewer] settings.json parse failed: %@", err);
    return;
  }
  self.settingsDict = [((NSDictionary*)json) mutableCopy];
  NSLog(@"[PdfWinViewer] settings loaded with %lu keys",
        (unsigned long)self.settingsDict.count);
}

- (void)saveSettingsJSON {
  if (!self.settingsDict) {
    self.settingsDict = [NSMutableDictionary new];
  }
  NSError* err = nil;
  NSData* data =
      [NSJSONSerialization dataWithJSONObject:self.settingsDict
                                      options:NSJSONWritingPrettyPrinted
                                        error:&err];
  if (err || !data) {
    NSLog(@"[PdfWinViewer] Failed to serialize settings.json: %@", err);
    return;
  }
  NSString* path = [self settingsJSONPath];
  BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&err];
  if (!ok || err) {
    NSLog(@"[PdfWinViewer] Failed to write settings.json: %@", err);
  } else {
    NSLog(@"[PdfWinViewer] settings.json saved OK");
  }
}

- (void)extractRecentFromSettings {
  self.recentPaths = [NSMutableArray new];
  id arr = self.settingsDict[@"recent_files"];
  if (![arr isKindOfClass:[NSArray class]]) {
    NSLog(@"[PdfWinViewer] settings has no recent_files (or wrong type)");
    return;
  }
  for (id item in (NSArray*)arr) {
    if ([item isKindOfClass:[NSString class]] &&
        [((NSString*)item) length] > 0) {
      if (![self.recentPaths containsObject:item]) {
        [self.recentPaths addObject:item];
      }
      if (self.recentPaths.count >= 10) {
        break;
      }
    }
  }
  NSLog(@"[PdfWinViewer] recent_files loaded: %@", self.recentPaths);
}

- (void)persistRecentIntoSettings {
  if (!self.settingsDict) {
    self.settingsDict = [NSMutableDictionary new];
  }
  self.settingsDict[@"recent_files"] = [self.recentPaths copy];
  [self saveSettingsJSON];
}

@end

