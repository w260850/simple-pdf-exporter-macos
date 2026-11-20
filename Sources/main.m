#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import <CoreText/CoreText.h>

static NSSet<NSString *> *SupportedExtensions(void) {
    return [NSSet setWithArray:@[@"docx", @"doc", @"odt", @"pdf", @"png", @"jpg", @"jpeg", @"heic", @"tif", @"tiff", @"gif", @"bmp", @"txt", @"md", @"markdown", @"csv", @"html", @"htm", @"rtf"]];
}

static NSURL *OutputURL(NSURL *source, NSFileManager *fm) {
    NSURL *directory = source.URLByDeletingLastPathComponent;
    NSString *stem = source.URLByDeletingPathExtension.lastPathComponent;
    NSURL *candidate = [[directory URLByAppendingPathComponent:stem] URLByAppendingPathExtension:@"pdf"];
    NSInteger suffix = 2;
    while ([candidate.path isEqualToString:source.path] || [fm fileExistsAtPath:candidate.path]) {
        candidate = [[directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%ld", stem, (long)suffix]] URLByAppendingPathExtension:@"pdf"];
        suffix++;
    }
    return candidate;
}

static BOOL ConvertImage(NSURL *source, NSURL *destination, NSError **error) {
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:source];
    if (!image) {
        if (error) *error = [NSError errorWithDomain:@"SimplePDF" code:2 userInfo:@{NSLocalizedDescriptionKey:@"无法读取图片"}];
        return NO;
    }
    NSRect page = NSMakeRect(0, 0, 595, 842);
    NSImageView *view = [[NSImageView alloc] initWithFrame:page];
    view.image = image;
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    view.imageFrameStyle = NSImageFrameNone;
    NSData *pdf = [view dataWithPDFInsideRect:page];
    return [pdf writeToURL:destination options:NSDataWritingAtomic error:error];
}

static BOOL ConvertText(NSURL *source, NSURL *destination, NSError **error) {
    NSString *ext = source.pathExtension.lowercaseString;
    NSData *data = [NSData dataWithContentsOfURL:source options:0 error:error];
    if (!data) return NO;
    NSAttributedString *content = nil;
    NSDictionary *options = nil;
    if ([ext isEqualToString:@"rtf"]) options = @{NSDocumentTypeDocumentAttribute:NSRTFTextDocumentType};
    if ([ext isEqualToString:@"html"] || [ext isEqualToString:@"htm"]) options = @{NSDocumentTypeDocumentAttribute:NSHTMLTextDocumentType, NSCharacterEncodingDocumentAttribute:@(NSUTF8StringEncoding)};
    if (options) content = [[NSAttributedString alloc] initWithData:data options:options documentAttributes:nil error:error];
    else {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) text = [[NSString alloc] initWithData:data encoding:NSUnicodeStringEncoding];
        if (!text) {
            if (error) *error = [NSError errorWithDomain:@"SimplePDF" code:3 userInfo:@{NSLocalizedDescriptionKey:@"无法识别文本编码"}];
            return NO;
        }
        content = [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular], NSForegroundColorAttributeName:NSColor.blackColor}];
    }
    if (!content) return NO;

    CGRect page = CGRectMake(0, 0, 595, 842);
    CGRect body = CGRectInset(page, 44, 48);
    CGDataConsumerRef consumer = CGDataConsumerCreateWithURL((__bridge CFURLRef)destination);
    if (!consumer) return NO;
    CGContextRef context = CGPDFContextCreate(consumer, &page, NULL);
    CGDataConsumerRelease(consumer);
    if (!context) return NO;
    CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)content);
    CFIndex position = 0;
    do {
        CGPDFContextBeginPage(context, NULL);
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, 0, page.size.height);
        CGContextScaleCTM(context, 1, -1);
        CGPathRef path = CGPathCreateWithRect(body, NULL);
        CTFrameRef frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(position, 0), path, NULL);
        CTFrameDraw(frame, context);
        CFRange visible = CTFrameGetVisibleStringRange(frame);
        position += visible.length;
        CFRelease(frame); CGPathRelease(path);
        CGContextRestoreGState(context);
        CGPDFContextEndPage(context);
        if (visible.length == 0) break;
    } while (position < content.length);
    CFRelease(framesetter);
    CGPDFContextClose(context);
    CGContextRelease(context);
    return [NSFileManager.defaultManager fileExistsAtPath:destination.path];
}

static BOOL ConvertWord(NSURL *source, NSURL *destination, NSError **error) {
    NSTask *task = NSTask.new;
    NSURL *script = [NSBundle.mainBundle URLForResource:@"convert-word" withExtension:@"js"];
    if (!script) {
        if (error) *error = [NSError errorWithDomain:@"SimplePDF" code:4 userInfo:@{NSLocalizedDescriptionKey:@"应用内缺少 Word 转换组件"}];
        return NO;
    }
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    task.arguments = @[@"-l", @"JavaScript", script.path, source.path, destination.path];
    NSPipe *diagnostics = NSPipe.pipe;
    task.standardError = diagnostics;
    @try {
        [task launchAndReturnError:error];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"SimplePDF" code:4 userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Word 文档解析失败"}];
        return NO;
    }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:destination.path error:nil];
    BOOL producedOutput = [attributes[NSFileSize] unsignedLongLongValue] > 0;
    if (task.terminationStatus != 0 || !producedOutput) {
        NSData *data = [diagnostics.fileHandleForReading readDataToEndOfFile];
        NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *friendly = message.length ? message : @"Pages 未能导出此 Word 文档；请确认已安装 Pages，并允许本工具控制 Pages";
        if (error) *error = [NSError errorWithDomain:@"SimplePDF" code:5 userInfo:@{NSLocalizedDescriptionKey:friendly}];
        [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
        return NO;
    }
    return YES;
}

static NSURL *ConvertFile(NSURL *source, NSError **error) {
    NSString *ext = source.pathExtension.lowercaseString;
    if (![SupportedExtensions() containsObject:ext]) {
        if (error) *error = [NSError errorWithDomain:@"SimplePDF" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"暂不支持 .%@ 文件", ext.length ? ext : @"(无扩展名)"]}];
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *destination = OutputURL(source, fm);
    BOOL success;
    if ([ext isEqualToString:@"pdf"]) success = [fm copyItemAtURL:source toURL:destination error:error];
    else if ([@[@"docx", @"doc", @"odt"] containsObject:ext]) success = ConvertWord(source, destination, error);
    else if ([@[@"png", @"jpg", @"jpeg", @"heic", @"tif", @"tiff", @"gif", @"bmp"] containsObject:ext]) success = ConvertImage(source, destination, error);
    else success = ConvertText(source, destination, error);
    return success ? destination : nil;
}

@interface DropView : NSView <NSTableViewDataSource, NSTableViewDelegate>
@property NSMutableArray<NSMutableDictionary *> *tasks;
@property NSTableView *table;
@property NSTextField *dropTitle;
@end

@implementation DropView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _tasks = NSMutableArray.array;
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        [self buildUI];
    }
    return self;
}
- (void)buildUI {
    NSBox *drop = [[NSBox alloc] initWithFrame:NSZeroRect];
    drop.boxType = NSBoxCustom;
    drop.cornerRadius = 18;
    drop.borderWidth = 2;
    drop.borderColor = [NSColor separatorColor];
    drop.fillColor = [NSColor controlBackgroundColor];
    drop.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:drop];

    NSTextField *icon = [NSTextField labelWithString:@"⇩ PDF"];
    icon.font = [NSFont systemFontOfSize:34 weight:NSFontWeightLight];
    icon.alignment = NSTextAlignmentCenter;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [drop addSubview:icon];
    _dropTitle = [NSTextField labelWithString:@"拖入文件，导出为 PDF"];
    _dropTitle.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    _dropTitle.alignment = NSTextAlignmentCenter;
    _dropTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [drop addSubview:_dropTitle];
    NSTextField *formats = [NSTextField labelWithString:@"主要支持 Word（DOCX），另支持图片、文本、HTML、RTF、PDF"];
    formats.textColor = NSColor.secondaryLabelColor;
    formats.alignment = NSTextAlignmentCenter;
    formats.translatesAutoresizingMaskIntoConstraints = NO;
    [drop addSubview:formats];
    NSButton *choose = [NSButton buttonWithTitle:@"选择文件…" target:self action:@selector(chooseFiles:)];
    choose.translatesAutoresizingMaskIntoConstraints = NO;
    [drop addSubview:choose];

    NSTextField *heading = [NSTextField labelWithString:@"转换任务"];
    heading.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:heading];
    NSTextField *hint = [NSTextField labelWithString:@"输出到源文件目录"];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:hint];

    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"task"];
    column.title = @"任务";
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.rowHeight = 52;
    _table.dataSource = self;
    _table.delegate = self;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = _table;
    scroll.hasVerticalScroller = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [drop.topAnchor constraintEqualToAnchor:self.topAnchor constant:20], [drop.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20], [drop.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20], [drop.heightAnchor constraintEqualToConstant:220],
        [icon.centerXAnchor constraintEqualToAnchor:drop.centerXAnchor], [icon.topAnchor constraintEqualToAnchor:drop.topAnchor constant:28],
        [_dropTitle.centerXAnchor constraintEqualToAnchor:drop.centerXAnchor], [_dropTitle.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:8],
        [formats.centerXAnchor constraintEqualToAnchor:drop.centerXAnchor], [formats.topAnchor constraintEqualToAnchor:_dropTitle.bottomAnchor constant:8],
        [choose.centerXAnchor constraintEqualToAnchor:drop.centerXAnchor], [choose.topAnchor constraintEqualToAnchor:formats.bottomAnchor constant:14],
        [heading.topAnchor constraintEqualToAnchor:drop.bottomAnchor constant:18], [heading.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
        [hint.centerYAnchor constraintEqualToAnchor:heading.centerYAnchor], [hint.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20],
        [scroll.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:10], [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20], [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20], [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-20]
    ]];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { self.dropTitle.textColor = NSColor.controlAccentColor; return NSDragOperationCopy; }
- (void)draggingExited:(id<NSDraggingInfo>)sender { self.dropTitle.textColor = NSColor.labelColor; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.dropTitle.textColor = NSColor.labelColor;
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    [self addURLs:urls]; return urls.count > 0;
}
- (void)chooseFiles:(id)sender {
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.allowsMultipleSelection = YES; panel.canChooseDirectories = NO;
    if ([panel runModal] == NSModalResponseOK) [self addURLs:panel.URLs];
}
- (void)addURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        NSMutableDictionary *task = [@{@"source":url, @"status":@"正在转换…", @"color":NSColor.secondaryLabelColor} mutableCopy];
        [self.tasks insertObject:task atIndex:0];
        [self.table reloadData];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil; NSURL *output = ConvertFile(url, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (output) { task[@"status"] = [NSString stringWithFormat:@"✓ 已完成 · %@", output.lastPathComponent]; task[@"color"] = NSColor.systemGreenColor; task[@"output"] = output; }
                else { task[@"status"] = [NSString stringWithFormat:@"✕ 转换失败 · %@", error.localizedDescription ?: @"未知错误"]; task[@"color"] = NSColor.systemRedColor; }
                [self.table reloadData];
            });
        });
    }
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.tasks.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSDictionary *task = self.tasks[row];
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableView.bounds.size.width, 52)];
    NSTextField *name = [NSTextField labelWithString:[task[@"source"] lastPathComponent]];
    name.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium]; name.frame = NSMakeRect(10, 27, tableView.bounds.size.width - 40, 18);
    NSTextField *status = [NSTextField labelWithString:task[@"status"]];
    status.font = [NSFont systemFontOfSize:11]; status.textColor = task[@"color"]; status.frame = NSMakeRect(10, 7, tableView.bounds.size.width - 40, 17);
    [cell addSubview:name]; [cell addSubview:status]; return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.table.selectedRow;
    if (row >= 0 && self.tasks[row][@"output"]) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[self.tasks[row][@"output"]]];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@end
@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 540) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"简易 PDF 导出工具";
    self.window.minSize = NSMakeSize(640, 480);
    self.window.contentView = [[DropView alloc] initWithFrame:self.window.contentView.bounds];
    [self.window center]; [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

static int SelfTest(void) {
    NSURL *source = [NSURL fileURLWithPath:@"/tmp/report.pdf"];
    NSURL *output = OutputURL(source, NSFileManager.defaultManager);
    if ([output.path isEqualToString:source.path] || ![SupportedExtensions() containsObject:@"docx"] || ![SupportedExtensions() containsObject:@"heic"] || ![SupportedExtensions() containsObject:@"md"]) return 1;
    puts("Self-test passed"); return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) return SelfTest();
        if (argc > 2 && strcmp(argv[1], "--convert") == 0) {
            NSError *error = nil;
            NSURL *output = ConvertFile([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]], &error);
            if (!output) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
            puts(output.path.UTF8String); return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = AppDelegate.new;
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
