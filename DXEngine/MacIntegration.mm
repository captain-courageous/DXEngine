#include "Precomp.h"
#include "Engine.h"
#include "LauncherSettings.h"
#include "Package/PackageManager.h"
#include "Packages/Extension/Windows/TabGroup/URootWindow.h"
#include "Packages/Extension/Windows/Text/UEditWindow.h"
#include <dxwidgets/window/cocoanativehandle.h>
#import "../DXWidgets/src/window/cocoa/AppKitWrapper.h"
#import <GameController/GameController.h>
#import <notify.h>

static UEditWindow* FocusedEdit()
{
    return engine && engine->dxRootWindow ? UObject::TryCast<UEditWindow>(engine->dxRootWindow->FocusWindow()) : nullptr;
}

@interface DeusExMacActions : NSObject <NSMenuItemValidation>
@end
@implementation DeusExMacActions
- (void)quit:(id)sender { if (engine) engine->OnWindowClose(); }
- (void)edit:(NSMenuItem*)sender
{
    auto* edit = FocusedEdit();
    if (!edit) return;
    switch (sender.tag) {
        case 0: edit->Undo(); break;
        case 1: edit->Redo(); break;
        case 2: edit->Cut(); break;
        case 3: edit->Copy(); break;
        case 4: edit->Paste(); break;
        case 5: edit->SetSelectedArea(0, (int)edit->Text().size()); break;
    }
}
- (void)setting:(NSMenuItem*)sender
{
    double value = [sender.representedObject doubleValue];
    if (sender.tag == 0) {
        engine->renderScale = (float)value;
        LauncherSettings::Get().Performance.RenderScale = (float)value;
        [NSUserDefaults.standardUserDefaults setDouble:value forKey:@"RenderScale"];
    } else if (sender.tag == 1) {
        engine->interfaceScale = (float)value;
        [NSUserDefaults.standardUserDefaults setDouble:value forKey:@"InterfaceScale"];
        if (engine->dxRootWindow) engine->dxRootWindow->AskParentForReconfigure();
    } else if (sender.tag == 3) {
        engine->classicAspectRatio = value != 0;
        [NSUserDefaults.standardUserDefaults setBool:engine->classicAspectRatio forKey:@"ClassicAspectRatio"];
        if (engine->dxRootWindow) engine->dxRootWindow->AskParentForReconfigure();
    } else {
        LauncherSettings::Get().Gamepad.Enabled = !LauncherSettings::Get().Gamepad.Enabled;
        [NSUserDefaults.standardUserDefaults setBool:LauncherSettings::Get().Gamepad.Enabled forKey:@"ControllerEnabled"];
    }
}
- (BOOL)validateMenuItem:(NSMenuItem*)item
{
    if (item.action == @selector(edit:)) return FocusedEdit() != nullptr;
    if (item.action == @selector(setting:)) {
        if (item.tag == 2) item.state = LauncherSettings::Get().Gamepad.Enabled ? NSControlStateValueOn : NSControlStateValueOff;
        else if (item.tag == 3) item.state = engine->classicAspectRatio == [item.representedObject boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        else {
            float current = item.tag == 0 ? engine->renderScale : engine->interfaceScale;
            item.state = std::abs(current - [item.representedObject floatValue]) < 0.01f ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    return YES;
}
@end

void Engine::InitializeMacIntegration()
{
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"RenderScale": @1.0, @"InterfaceScale": @1.0, @"ControllerEnabled": @YES, @"ClassicAspectRatio": @NO}];
    auto setting = [](NSString* key, float low, float high) {
        float value = [NSUserDefaults.standardUserDefaults floatForKey:key];
        return std::isfinite(value) ? std::clamp(value, low, high) : 1.0f;
    };
    renderScale = setting(@"RenderScale", 0.5f, 1.0f);
    LauncherSettings::Get().Performance.RenderScale = renderScale;
    interfaceScale = setting(@"InterfaceScale", 0.75f, 1.25f);
    LauncherSettings::Get().Gamepad.Enabled = [NSUserDefaults.standardUserDefaults boolForKey:@"ControllerEnabled"];
    classicAspectRatio = [NSUserDefaults.standardUserDefaults boolForKey:@"ClassicAspectRatio"];
    static DeusExMacActions* actions = [DeusExMacActions new];
    NSMenu* bar = [NSMenu new];
    auto menu = [&](NSString* title) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        item.submenu = [[NSMenu alloc] initWithTitle:title];
        [bar addItem:item]; return item.submenu;
    };
    NSMenu* app = menu(@"Deus Ex");
    [app addItemWithTitle:@"Hide Deus Ex" action:@selector(hide:) keyEquivalent:@"h"];
    [app addItem:[NSMenuItem separatorItem]];
    auto quit = [app addItemWithTitle:@"Quit Deus Ex" action:@selector(quit:) keyEquivalent:@"q"]; quit.target = actions;
    NSMenu* edit = menu(@"Edit");
    NSArray* titles = @[@"Undo", @"Redo", @"Cut", @"Copy", @"Paste", @"Select All"];
    NSArray* keys = @[@"z", @"z", @"x", @"c", @"v", @"a"];
    for (int i=0; i<6; ++i) {
        auto item = [edit addItemWithTitle:titles[i] action:@selector(edit:) keyEquivalent:keys[i]];
        item.tag = i; item.target = actions;
        item.keyEquivalentModifierMask = NSEventModifierFlagCommand | (i == 1 ? NSEventModifierFlagShift : 0);
    }
    NSMenu* view = menu(@"View");
    for (int type=0; type<2; ++type) {
        auto title = type == 0 ? @"Rendering Resolution" : @"Interface Size";
        auto parent = [view addItemWithTitle:title action:nil keyEquivalent:@""];
        parent.submenu = [[NSMenu alloc] initWithTitle:title];
        NSArray* values = type == 0 ? @[@50, @75, @100] : @[@75, @100, @125];
        for (NSNumber* percent in values) {
            auto item = [parent.submenu addItemWithTitle:[NSString stringWithFormat:@"%@%%", percent] action:@selector(setting:) keyEquivalent:@""];
            item.target = actions; item.tag = type; item.representedObject = @([percent doubleValue] / 100.0);
        }
    }
    auto aspect = [view addItemWithTitle:@"Aspect Ratio" action:nil keyEquivalent:@""];
    aspect.submenu = [[NSMenu alloc] initWithTitle:@"Aspect Ratio"];
    for (int classic = 0; classic < 2; ++classic) {
        auto item = [aspect.submenu addItemWithTitle:classic ? @"4:3 (Classic)" : @"Fit Window" action:@selector(setting:) keyEquivalent:@""];
        item.target = actions; item.tag = 3; item.representedObject = @(classic);
    }
    auto controller = [view addItemWithTitle:@"Enable Controller" action:@selector(setting:) keyEquivalent:@""];
    controller.target = actions; controller.tag = 2;
    NSMenu* windows = menu(@"Window");
    auto* handle = static_cast<CocoaNativeHandle*>(window->GetNativeHandle());
    auto full = [windows addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    full.target = handle->nsWindow; full.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    [NSApp setMainMenu:bar]; [NSApp setWindowsMenu:windows];
    [NSApp activateIgnoringOtherApps:YES];
    [handle->nsWindow makeKeyAndOrderFront:nil];
    fprintf(stderr, "macOS integration initialized: render=%.2f UI=%.2f controller=%d bundle=%s GameModeOptIn=%d\n", renderScale, interfaceScale, (int)LauncherSettings::Get().Gamepad.Enabled, NSBundle.mainBundle.bundleIdentifier.UTF8String, [NSBundle.mainBundle.infoDictionary[@"LSSupportsGameMode"] boolValue]);
}

void Engine::PollMacStatus()
{
    @autoreleasepool {
        static int gameModeToken = -1, fullscreenToken = -1;
        static CFTimeInterval lastStatusTime = 0;
        static std::string lastStatus;
        if (gameModeToken == -1) {
            notify_register_check("com.apple.system.game_mode_status_changed", &gameModeToken);
            notify_register_check("com.apple.system.fullscreen_gaming_session_changed", &fullscreenToken);
        }
        if (CACurrentMediaTime() - lastStatusTime > 1.0) {
            lastStatusTime = CACurrentMediaTime();
            uint64_t gameMode = 0, fullscreenSession = 0;
            notify_get_state(gameModeToken, &gameMode); notify_get_state(fullscreenToken, &fullscreenSession);
            if (window) {
                void* handle = window->GetNativeHandle();
                if (handle) {
                    NSWindow* nsWindow = static_cast<CocoaNativeHandle*>(handle)->nsWindow;
                    if (nsWindow && (!NSApp.active || !nsWindow.keyWindow)) {
                        [NSApp activateIgnoringOtherApps:YES];
                        [nsWindow makeKeyAndOrderFront:nil];
                    }
                    std::string status = "active=" + std::to_string(NSApp.active) + " key=" + std::to_string(nsWindow.keyWindow)
                        + " fullscreen=" + std::to_string(bool(nsWindow.styleMask & NSWindowStyleMaskFullScreen))
                        + " appRunning=" + std::to_string(NSApp.running) + " gameMode=" + std::to_string(gameMode)
                        + " fullscreenGameSession=" + std::to_string(fullscreenSession);
                    if (status != lastStatus) { fprintf(stderr, "macOS gaming status: %s\n", status.c_str()); lastStatus = status; }
                }
            }
        }
    }
}
