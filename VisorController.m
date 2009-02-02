//
//  VisorController.m
//  Visor
//
//  Created by Nicholas Jitkoff on 6/1/06.
//  Copyright 2006 __MyCompanyName__. All rights reserved.
//

#import "VisorController.h"
#import "VisorWindow.h"
#import "NDHotKeyEvent_QSMods.h"
#import "VisorTermController.h"
#import <QuartzComposer/QuartzComposer.h>
#import "CGSPrivate.h"

#define VisorTerminalDefaults @"VisorTerminal" 

NSString* stringForCharacter(const unsigned short aKeyCode, unichar aCharacter);

@implementation VisorController

+ (VisorController*) sharedInstance {
    static VisorController* plugin = nil;
    if (plugin == nil)
        plugin = [[VisorController alloc] init];
    return plugin;
}

+ (void) install {
    NSDictionary *defaults=[NSDictionary dictionaryWithContentsOfFile:[[NSBundle bundleForClass:[self class]]pathForResource:@"Defaults" ofType:@"plist"]];
    [[NSUserDefaults standardUserDefaults]registerDefaults:defaults];
    [VisorController sharedInstance];
}

- (id) init {
    self = [super init];
    if (!self) return self;

    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    NSUserDefaultsController* udc = [NSUserDefaultsController sharedUserDefaultsController];

    previouslyActiveApp = nil;
    hidden = true;

    NSDictionary *defaults=[NSDictionary dictionaryWithContentsOfFile:[[NSBundle bundleForClass:[self class]]pathForResource:@"Defaults" ofType:@"plist"]];
    [ud registerDefaults:defaults];
    
    hotkey=nil;
    [NSBundle loadNibNamed:@"Visor" owner:self];

    // if the default VisorShowStatusItem doesn't exist, set it to true by default
    if (![ud objectForKey:@"VisorShowStatusItem"]) {
        [ud setBool:YES forKey:@"VisorShowStatusItem"];
    }
    
    // add the "Visor Preferences..." item to the Terminal menu
    id <NSMenuItem> prefsMenuItem = [[statusMenu itemAtIndex:[statusMenu numberOfItems] - 1] copy];
    [[[[NSApp mainMenu] itemAtIndex:0] submenu] insertItem:prefsMenuItem atIndex:3];
    [prefsMenuItem release];
    
    if ([ud  boolForKey:@"VisorShowStatusItem"]) {
        [self activateStatusMenu];
    }
    
    [self enableHotKey];
    [self initEscapeKey];
    
    // watch for hotkey changes
    [udc addObserver:self forKeyPath:@"values.VisorHotKey" options:nil context:nil];
    [udc addObserver:self forKeyPath:@"values.VisorBackgroundAnimationFile" options:nil context:nil];
    [udc addObserver:self forKeyPath:@"values.VisorUseFade" options:nil context:nil];                                                           
    [udc addObserver:self forKeyPath:@"values.VisorUseSlide" options:nil context:nil];               
    [udc addObserver:self forKeyPath:@"values.VisorAnimationSpeed" options:nil context:nil];
    [udc addObserver:self forKeyPath:@"values.VisorShowStatusItem" options:nil context:nil];
    
    [self controller]; // calls createController
    if ([ud boolForKey:@"VisorUseBackgroundAnimation"]) {
        [self backgroundWindow];
    }
    return self;
}

- (void)createController {
    if (controller) return;

    NSDisableScreenUpdates();
    NSNotificationCenter* dnc = [NSNotificationCenter defaultCenter];
    id profile = [[TTProfileManager sharedProfileManager] profileWithName:@"Visor"];
    controller = [NSApp newWindowControllerWithProfile:profile];

    NSWindow *window=[controller window];
    [window setLevel:NSFloatingWindowLevel];
    [window setOpaque:NO];
    [self placeWindowOffScreen:window];

    [dnc addObserver:self selector:@selector(resignMain:) name:NSWindowDidResignMainNotification object:window];
    [dnc addObserver:self selector:@selector(resignKey:) name:NSWindowDidResignKeyNotification object:window];
    [dnc addObserver:self selector:@selector(becomeKey:) name:NSWindowDidBecomeKeyNotification object:window];
    [dnc addObserver:self selector:@selector(resized:) name:NSWindowDidResizeNotification object:window];
    NSEnableScreenUpdates();
}

- (BOOL)validateMenuItem:(id <NSMenuItem>)menuItem {
    if ([menuItem action]==@selector(toggleVisor:)){
        [menuItem setKeyEquivalent:stringForCharacter([hotkey keyCode],[hotkey character])];
        [menuItem setKeyEquivalentModifierMask:[hotkey modifierFlags]];
    }
    return YES;
}

- (IBAction)showPrefs:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [prefsWindow center];
    [prefsWindow makeKeyAndOrderFront:nil];
}
 
- (IBAction)showAboutBox:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [aboutWindow center];
    [aboutWindow makeKeyAndOrderFront:nil];
}

- (void)activateStatusMenu {
    NSStatusBar *bar = [NSStatusBar systemStatusBar];
    statusItem = [bar statusItemWithLength:NSVariableStatusItemLength];
    [statusItem retain];
    
    // Set Icon
    NSString *imagePath=[[NSBundle bundleForClass:[self classForCoder]]pathForImageResource:@"Visor"];
    NSImage *image=[[[NSImage alloc]initWithContentsOfFile:imagePath]autorelease];
    [statusItem setImage:image];
    
    [statusItem setHighlightMode:YES];
    [statusItem setTarget:self];
    [statusItem setAction:@selector(toggleVisor:)];
    [statusItem setDoubleAction:@selector(toggleVisor:)];
    
    [statusItem setMenu:statusMenu];
}

- (IBAction)toggleVisor:(id)sender {
    if (hidden){
        [self showWindow];
    }else{
        [self hideWindow];
    }
}

- (void)placeWindowOffScreen:(id)window {
    BOOL useBackground = [[NSUserDefaults standardUserDefaults]boolForKey:@"VisorUseBackgroundAnimation"];
    NSScreen *screen=[NSScreen mainScreen];
    NSRect screenRect=[screen frame];
    screenRect.size.height-=21; // ignore menu area
    NSRect showFrame=screenRect; // shown Frame
    showFrame=[window frame]; // respect the existing height
    showFrame.size.width=screenRect.size.width; // make it the full screen width
    [window setFrame:showFrame display:NO];
    showFrame.origin.x+=NSMidX(screenRect)-NSMidX(showFrame); // center horizontally
    showFrame.origin.y=NSMaxY(screenRect); // move above top of screen
    [window setFrame:showFrame display:NO];
    if (useBackground) {
        [self backgroundWindow];
        [[backgroundWindow contentView]startRendering];
        [backgroundWindow setFrame:showFrame display:YES];
        [backgroundWindow orderFront:nil];
        [backgroundWindow setLevel:NSMainMenuWindowLevel-2];    
    } else {
        [self setBackgroundWindow:nil];
    }
    [window setLevel:NSMainMenuWindowLevel-1];
}

- (void)showWindow {
    if (!hidden) return;
    hidden = false;
    [self maybeEnableEscapeKey:YES];
    
    NSDictionary *activeAppDict = [[NSWorkspace sharedWorkspace] activeApplication];
    if (previouslyActiveApp) {
        [previouslyActiveApp release];
        previouslyActiveApp = nil;
    }
    if ([[activeAppDict objectForKey:@"NSApplicationBundleIdentifier"] compare:@"com.apple.Terminal"]) {
        previouslyActiveApp = [[NSString alloc] initWithString:[activeAppDict objectForKey:@"NSApplicationPath"]];
    }
    [NSApp activateIgnoringOtherApps:YES];
    NSWindow *window=[[self controller] window];
    [window makeKeyAndOrderFront:self];
    [window makeFirstResponder:[[controller selectedTabController] view]];
    [self placeWindowOffScreen:window];
    [window setHasShadow:YES];
    [self slideWindows:1];
    [window invalidateShadow];
}

- (void)didEndSheet:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
}

-(void)hideWindow {
    if (hidden) return;
    hidden = true;
    [self maybeEnableEscapeKey:NO];
    if (previouslyActiveApp) {
        NSDictionary *scriptError = [[NSDictionary alloc] init]; 
        NSString *scriptSource = [NSString stringWithFormat: @"tell application \"%@\" to activate ", previouslyActiveApp]; 
        NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:scriptSource]; 
        [appleScript executeAndReturnError: &scriptError];
        [appleScript release];
        [scriptError release];
        [previouslyActiveApp release];
        previouslyActiveApp = nil;
    }
    
    NSWindow *window=[[self controller] window];
    NSScreen *screen=[NSScreen mainScreen];
    NSRect screenRect=[screen frame];   
    NSRect showFrame=screenRect; // Shown Frame
    NSRect hideFrame=NSOffsetRect(showFrame,0,NSHeight(screenRect)/2+22); //hidden frame for start of animation
                                                                          ///   if ([[NSUserDefaults standardUserDefaults]boolForKey:@"VisorUseBackgroundAnimation"]
                                                                          //    [window setLevel:NSFloatingWindowLevel];
    [self saveDefaults];
    [self slideWindows:0];
    [window setHasShadow:NO];
    
    [[backgroundWindow contentView]stopRendering];
}

- (void)slideWindows:(BOOL)show {
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc]init];
    NSWindow *window=[[self controller] window];
    float windowHeight=NSHeight([window frame]);
    CGSConnection cgs = _CGSDefaultConnection();
    int wids[2]={[window windowNumber],[backgroundWindow windowNumber]};
    
    CGAffineTransform transform;
    CGSGetWindowTransform(cgs,wids[0],&transform);
    
    CGAffineTransform newTransforms[2];
    float newAlphas[2]; 
    NSTimeInterval t;
    NSDate *date=[NSDate date];
    int windowCount=backgroundWindow?2:1;
    
    // added drp
    float DURATION=[[NSUserDefaults standardUserDefaults]floatForKey:@"VisorAnimationSpeed"];
    
    int windowHeightDelta = 500;
    // added drp
    // if we dont have to animate, dont really bother.
    if(![[NSUserDefaults standardUserDefaults]boolForKey:@"VisorUseSlide"] && ![[NSUserDefaults standardUserDefaults]boolForKey:@"VisorUseFade"])
        DURATION=0.1;

    while (DURATION>(t=-[date timeIntervalSinceNow])) {
        float f=t/DURATION;
        
        newTransforms[0]=newTransforms[1]=CGAffineTransformTranslate(transform,0,(show?-1:1)*sin(M_PI_2*f)*(windowHeight));
        
        // added drp do we fade in or not?
        if ([[NSUserDefaults standardUserDefaults]boolForKey:@"VisorUseFade"])
        {
            if (backgroundWindow)
                CGSSetWindowAlpha(cgs, wids[1], 1.0f-(f*1.1)); //background fades faster
            CGSSetWindowAlpha(cgs, wids[0], 1.0f-f);
        }
        else
        {
            if (backgroundWindow)
                CGSSetWindowAlpha(cgs, wids[1], 1.0f);
            CGSSetWindowAlpha(cgs, wids[0], 1.0f);
            
        }
        
        // added drp - do we animate the slide?
        if ([[NSUserDefaults standardUserDefaults]boolForKey:@"VisorUseSlide"])
        {
            CGSSetWindowTransforms(cgs, wids, newTransforms, windowCount); 
        }
        
        //[backgroundWindow display];
        usleep(5000);
    }
    
    
    newTransforms[0]=newTransforms[1]=CGAffineTransformTranslate(transform,0,(show?-1:1)*(windowHeight));
    CGSSetWindowTransforms(cgs, wids, newTransforms, windowCount); 
    CGSSetWindowAlpha(cgs, wids[1], 1);
    CGSSetWindowAlpha(cgs, wids[0], 1);
    [window setAlphaValue:1.0];  // NSWindow caches these values, so let it know
    [backgroundWindow setAlphaValue:1.0];
}

// Callback for a closed shell
- (void)shell:(id)shell childDidExitWithStatus:(int)status {
    [self hideWindow];
    [self setController:nil];
}

- (void)saveDefaults {   
//  NSDictionary *defaults=[[controller defaults]dictionaryRepresentation];
//  [[NSUserDefaults standardUserDefaults]setObject:defaults forKey:VisorTerminalDefaults];
}

- (void)resignMain:(id)sender {
    if (!hidden){
        [self hideWindow];  
    }
}

- (void)resignKey:(id)sender {
    if ([[controller window]isVisible]){
        [[controller window]setLevel:NSFloatingWindowLevel];
        [backgroundWindow setLevel:NSFloatingWindowLevel-1];
    }
}

- (void)becomeKey:(id)sender {
    if ([[controller window]isVisible]){
        [[controller window]setLevel:NSMainMenuWindowLevel-1];
        [backgroundWindow setLevel:NSMainMenuWindowLevel-2];
    }
}

- (void)windowResized {
    [backgroundWindow setFrame:[[controller window]frame] display:YES]; 
    [self saveDefaults];
}

- (IBAction)chooseFile:(id)sender {
    NSOpenPanel *panel=[NSOpenPanel openPanel];
    [panel setTitle:@"Select a Quartz Composer (qtz) file"];
    if ([panel runModalForTypes:[NSArray arrayWithObject:@"qtz"]]){
        NSString *path=[panel filename];
        path=[path stringByAbbreviatingWithTildeInPath];
        [[NSUserDefaults standardUserDefaults]setObject:path forKey:@"VisorBackgroundAnimationFile"];
        [[NSUserDefaults standardUserDefaults]setBool:YES forKey:@"VisorUseBackgroundAnimation"];
    }
}

- (void)resized:(NSNotification *)notif {
    if (!backgroundWindow) return;
    [backgroundWindow setFrame:[[controller window] frame] display:YES]; 
}

- (NSWindow *)backgroundWindow {
    if (backgroundWindow) return [[backgroundWindow retain] autorelease];

    backgroundWindow = [[[NSWindow class] alloc] initWithContentRect:NSZeroRect styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    [backgroundWindow setIgnoresMouseEvents:YES];
    [backgroundWindow setBackgroundColor: [NSColor blueColor]];
    [backgroundWindow setOpaque:NO];
    [backgroundWindow setHasShadow:NO];
    [backgroundWindow setReleasedWhenClosed:YES];
    [backgroundWindow setLevel:NSFloatingWindowLevel];
    [backgroundWindow setHasShadow:NO];
    QCView *content=[[[QCView alloc]init]autorelease];
    
    [backgroundWindow setContentView:content];
    
    NSString *path=[[NSUserDefaults standardUserDefaults]stringForKey:@"VisorBackgroundAnimationFile"];
    path=[path stringByStandardizingPath];
    
    NSFileManager *fm=[NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]){
        NSLog(@"animation does not exist: %@",path);
        path=nil;
    }
    
    if (!path)
        path=[[NSBundle bundleForClass:[self class]]pathForResource:@"Visor" ofType:@"qtz"];
    
    [content loadCompositionFromFile:path];
    [content startRendering];
    [content setMaxRenderingFrameRate:15.0];

    return [[backgroundWindow retain] autorelease];
}

- (void) setBackgroundWindow: (NSWindow *) newBackgroundWindow {
    if (backgroundWindow != newBackgroundWindow) {
        [backgroundWindow release];
        backgroundWindow = [newBackgroundWindow retain];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"values.VisorShowStatusItem"]) {
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"VisorShowStatusItem"]) {
            [self activateStatusMenu];
        } else {
            [statusItem release];
            statusItem=nil;
        }
    } else {
        [self enableHotKey];
        [self setBackgroundWindow:nil];
    }
}

- (void)enableHotKey {
    if (hotkey){
        [hotkey setEnabled:NO];
        [hotkey release];
        hotkey=nil;
    }
    NSDictionary *dict=[[NSUserDefaults standardUserDefaults]dictionaryForKey:@"VisorHotKey"];
    if (dict){
        hotkey=(QSHotKeyEvent *)[QSHotKeyEvent hotKeyWithDictionary:dict];
        [hotkey setTarget:self selectorReleased:(SEL)0 selectorPressed:@selector(toggleVisor:)];
        [hotkey setEnabled:YES];    
        [hotkey retain];
    }
}

- (void)initEscapeKey {
    escapeKey=(QSHotKeyEvent *)[QSHotKeyEvent hotKeyWithKeyCode:53 character:0 modifierFlags:0];
    [escapeKey setTarget:self selectorReleased:(SEL)0 selectorPressed:@selector(toggleVisor:)];
    [escapeKey setEnabled:NO];  
    [escapeKey retain];
}

- (void)maybeEnableEscapeKey:(BOOL)pEnable {
    if([[NSUserDefaults standardUserDefaults] boolForKey:@"VisorHideOnEscape"])
        [escapeKey setEnabled:pEnable];
}

- (TermController*)controller {
    if (!controller)[self createController];
    return [[controller retain] autorelease];
}

- (void)setController:(TermController *)value {
    if (controller==value) return;
    [controller release];
    controller = [value retain];
}

@end