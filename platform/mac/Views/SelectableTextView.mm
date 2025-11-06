//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import "SelectableTextView.h"

@implementation SelectableTextView

- (void)keyDown:(NSEvent*)event {
  NSString* chars = [event charactersIgnoringModifiers];
  unichar c = chars.length ? [chars characterAtIndex:0] : 0;
  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;

  // 处理 Cmd+A 全选
  if ((mods & NSEventModifierFlagCommand) && (c == 'a' || c == 'A')) {
    [self selectAll:nil];
    return;
  }

  // 其他按键交给父类处理
  [super keyDown:event];
}

- (BOOL)performKeyEquivalent:(NSEvent*)event {
  NSString* chars = [event charactersIgnoringModifiers];
  unichar c = chars.length ? [chars characterAtIndex:0] : 0;
  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;

  // 处理 Cmd+A 全选
  if ((mods & NSEventModifierFlagCommand) && (c == 'a' || c == 'A')) {
    [self selectAll:nil];
    return YES;
  }

  return [super performKeyEquivalent:event];
}

// 重写 copy: 方法，复制后清除选择
- (void)copy:(id)sender {
  // 调用父类的 copy 方法执行实际的复制操作
  [super copy:sender];

  // 复制完成后清除选择，使框选窗口消失
  [self setSelectedRange:NSMakeRange(0, 0)];
}

@end
