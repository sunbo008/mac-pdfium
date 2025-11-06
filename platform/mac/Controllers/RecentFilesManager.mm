#import "RecentFilesManager.h"
#import "../Utils/SettingsManager.h"

// 前向声明AppDelegate，避免循环依赖
@interface AppDelegate : NSObject
- (void)openPathAndAdjust:(NSString*)path;
@end

@implementation RecentFilesManager

- (void)rebuildRecentMenu {
  if (!self.recentMenu) {
    return;
  }
  [self.recentMenu removeAllItems];
  NSUInteger count = self.settingsManager.recentPaths.count;
  NSLog(@"[PdfWinViewer] rebuildRecentMenu count=%lu", (unsigned long)count);
  if (count == 0) {
    NSMenuItem* none = [[NSMenuItem alloc] initWithTitle:@"无最近项目"
                                                  action:nil
                                           keyEquivalent:@""];
    none.enabled = NO;
    [self.recentMenu addItem:none];
    self.recentMenuItem.enabled = NO;
    return;
  }
  self.recentMenuItem.enabled = YES;
  NSUInteger idx = 0;
  for (NSString* path in self.settingsManager.recentPaths) {
    NSLog(@"[PdfWinViewer] recent item %lu: %@", (unsigned long)idx, path);
    NSString* title =
        path.lastPathComponent.length ? path.lastPathComponent : path;
    // 带序号
    NSString* label =
        [NSString stringWithFormat:@"%lu. %@", (unsigned long)(idx + 1), title];
    NSMenuItem* it = [self.recentMenu addItemWithTitle:label
                                                action:@selector(openRecent:)
                                         keyEquivalent:@""];
    it.target = self;
    it.representedObject = path;
    idx++;
  }
  [self.recentMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* clear = [self.recentMenu addItemWithTitle:@"清空最近浏览"
                                                 action:@selector(clearRecent:)
                                          keyEquivalent:@""];
  clear.target = self;
}

- (void)addRecentPath:(NSString*)path {
  if (path.length == 0) {
    return;
  }
  if (!self.settingsManager.recentPaths) {
    self.settingsManager.recentPaths = [NSMutableArray new];
  }
  // 去重并置顶
  [self.settingsManager.recentPaths removeObject:path];
  [self.settingsManager.recentPaths insertObject:path atIndex:0];
  // 限制为最多 10 条
  while (self.settingsManager.recentPaths.count > 10) {
    [self.settingsManager.recentPaths removeLastObject];
  }
  // 持久化到 settings.json
  [self.settingsManager persistRecentIntoSettings];
  // 重建菜单
  [self rebuildRecentMenu];
  NSLog(@"[PdfWinViewer] addRecentPath done. paths=%@",
        self.settingsManager.recentPaths);
}

- (IBAction)openRecent:(id)sender {
  if (![sender isKindOfClass:[NSMenuItem class]]) {
    return;
  }
  NSString* path = ((NSMenuItem*)sender).representedObject;
  NSLog(@"[PdfWinViewer] openRecent: %@", path);
  if (path.length == 0) {
    return;
  }
  BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
  if (!exists) {
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"文件不存在";
    alert.informativeText = path;
    [alert runModal];
    // 从列表中移除并更新
    [self.settingsManager.recentPaths removeObject:path];
    [self.settingsManager persistRecentIntoSettings];
    [self rebuildRecentMenu];
    return;
  }
  [self.appDelegate openPathAndAdjust:path];
}

- (IBAction)clearRecent:(id)sender {
  [self.settingsManager.recentPaths removeAllObjects];
  [self.settingsManager persistRecentIntoSettings];
  [self rebuildRecentMenu];
}

@end

