//==============================================================================
/**
@file       MyStreamDeckPlugin.m

@brief      A Stream Deck plugin to provide a way to retain some clipboard data for re-use

@copyright  (c) 2022, Commit-La-Grenouille
			This source code is licensed under the GPLv3-style license found in the LICENSE file.

**/
//==============================================================================

#import "MyStreamDeckPlugin.h"

#import "ESDSDKDefines.h"
#import "ESDConnectionManager.h"
#import "ESDUtilities.h"
#import <AppKit/AppKit.h>


#define MIN_LONG_PRESS    1.0
#define SECURE_PRESS    3.0

// Size of the images
#define IMAGE_SIZE    144

// Text area boundaries within the post-it icons (top-left is START_X,MAX_Y)
#define SAFE_BORDER   7.0
#define START_X    SAFE_BORDER
#define START_Y    SAFE_BORDER
//#define MAX_X      IMAGE_SIZE - SAFE_BORDER
#define MAX_Y      IMAGE_SIZE - SAFE_BORDER
// Text in Andale Mono 14 about 16 chars (lowercase) to fit within the width of the post-it
#define LINE_LENGTH    16



// MARK: the static methods to help

//
// Utility function to get the fullpath of an resource in the bundle
//
static NSString * GetResourcePath(NSString *inFilename)
{
    NSString *outPath = nil;
    
    if([inFilename length] > 0)
    {
        NSString * bundlePath = [ESDUtilities pluginPath];
        if(bundlePath != nil)
        {
            outPath = [bundlePath stringByAppendingPathComponent:inFilename];
        }
    }
    
    return outPath;
}


//
// Utility function to create a CGContextRef
//
static CGContextRef CreateBitmapContext(CGSize inSize)
{
    CGFloat bitmapBytesPerRow = inSize.width * 4;
    CGFloat bitmapByteCount = (bitmapBytesPerRow * inSize.height);
    
    void *bitmapData = calloc(bitmapByteCount, 1);
    if(bitmapData == NULL)
    {
        return NULL;
    }
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bitmapData, inSize.width, inSize.height, 8, bitmapBytesPerRow, colorSpace, kCGImageAlphaPremultipliedLast);
    if(context == NULL)
    {
        CGColorSpaceRelease(colorSpace);
        free(bitmapData);
        return NULL;
    }
    else
    {
        CGColorSpaceRelease(colorSpace);
        return context;
    }
}


//
// Utility method that takes the path of an image and a string and returns the bitmap result
//
static CGImageRef ComposeImage(NSString *inImagePath, NSString *overlayText)
{
    CGImageRef completeImage = nil;
    
    NSImage* image = [[NSImage alloc] initWithContentsOfFile:inImagePath];
    if(image != nil)
    {
        // Find the best CGImageRef
        CGSize iconSize = CGSizeMake(IMAGE_SIZE, IMAGE_SIZE);
        NSRect theRect = NSMakeRect(0, 0, iconSize.width, iconSize.height);
        CGImageRef imageRef = [image CGImageForProposedRect:&theRect context:NULL hints:nil];
        if(imageRef != NULL)
        {
            // Create a CGContext
            CGContextRef context = CreateBitmapContext(iconSize);
            if(context != NULL)
            {
                // Draw the image
                CGContextDrawImage(context, theRect, imageRef);
                
                // Deal with the text if provided
                if (overlayText) {
                    //
                    // PART 1: transforming the basic string into a CoreText powerhouse
                    //
                    CGFloat fontSize = 14.0f;
                    // Choosing a monospaced font installed by default in macOS that deals well with small sizes
                    CTFontRef font = CTFontCreateWithName(CFSTR("Andale Mono"), fontSize, nil);
                    
                    // Do not forget that the attributes are fed backward (VALUE OBJ, KEY)
                    NSDictionary* attributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                                (__bridge id)font, kCTFontAttributeName,
                                                NSColor.systemYellowColor, NSForegroundColorAttributeName,
                                                    nil];
                    CFRelease(font);


                    // Preparing the initial trackers for our text wrapping needs
                    CGFloat strLenRemain = overlayText.length;
                    CGFloat offset_y = 0.0;
                    
                    while (strLenRemain >= LINE_LENGTH) {
                        //
                        // PART 2: slicing the text into pieces that could fit our constraints
                        //
                        NSAttributedString* overlayAttrStr = [[NSAttributedString alloc] initWithString:[overlayText substringFromIndex:overlayText.length-strLenRemain] attributes:attributes];
                        //
                        // TODO: could be improved by only taking the actual slice of text we will display
                        //       for more accurate measurements on the ascent/descent...
                        //
                        CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)overlayAttrStr);
                        
                        // Extracting some measurements of what remains of our line
                        CGFloat ascent, descent, leading;
                        CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
                        
                        //
                        // PART 3: rendering the lines inside the image we loaded
                        //
                        CGFloat x = START_X;
                        CGFloat y = MAX_Y - offset_y - ascent;
                        CGContextSetTextPosition(context, x, y);
                        CTLineDraw(line, context);
                        CFRelease(line);
                        
                        // Now we can prepare the values for the next line we wrap
                        strLenRemain -= LINE_LENGTH;
                        offset_y += ascent + descent;
                        
                        // We also want to detect if we are going too low to avoid bleeding off our background post-it
                        if (MAX_Y - offset_y <= START_Y * 2) {
                            strLenRemain = 0;
                        }
                    }
                }
                
                // Generate the final image
                completeImage = CGBitmapContextCreateImage(context);
            }
            CFRelease(context);
        }
    }
    return completeImage;
}


//
// Utility method that transforms an image into a base64 encoded string
//
static NSString * CreateBase64EncodedString(CGImageRef completeImage)
{
    NSString *outBase64PNG = nil;
    
    if(completeImage != NULL)
    {
        // Export the image to PNG
        CFMutableDataRef pngData = CFDataCreateMutable(kCFAllocatorDefault, 0);
        if(pngData != NULL)
        {
            CGImageDestinationRef destinationRef = CGImageDestinationCreateWithData(pngData, kUTTypePNG, 1, NULL);
            if (destinationRef != NULL)
            {
                CGImageDestinationAddImage(destinationRef, completeImage, nil);
                if (CGImageDestinationFinalize(destinationRef))
                {
                    NSString *base64PNG = [(__bridge NSData *)pngData base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithCarriageReturn];
                    if([base64PNG length] > 0)
                    {
                        outBase64PNG = [NSString stringWithFormat:@"data:image/png;base64,%@\">", base64PNG];
                    }
                }
                
                CFRelease(destinationRef);
            }
            
            CFRelease(pngData);
        }
        
        CFRelease(completeImage);
    }

    return outBase64PNG;
}


//
// Simple static method to keep the code accessing the dict of text simpler to read (and to maintain)
//
static NSString * keyFromCoord(NSDictionary * esdData) {
    return [NSString stringWithFormat:@"%@#%@", esdData[@"row"], esdData[@"column"]];
}


//
// Having a window dialog to grab a proper label to display with secure clipboard data
//
static NSString * askUserForLabel() {
    //
    // TODO: replace with objective-c code if it is less than Apollo-11 codebase ;o))
    //
    NSURL* url = [NSURL fileURLWithPath:GetResourcePath(@"secureLabelDialog.scpt")];

    NSDictionary *errors = nil;
    NSAppleScript* appleScript = [[NSAppleScript alloc] initWithContentsOfURL:url error:&errors];
    if(appleScript != nil) {
        NSAppleEventDescriptor *eventDescriptor = [appleScript executeAndReturnError:&errors];
        //
        // The applescript should return: {button returned:"OK", text returned:"tralala"}
        //
        if(eventDescriptor != nil && [eventDescriptor descriptorType] != kAENullEvent) {
            return [eventDescriptor stringValue];
        }
    }
    return @"???"; // So at least we know there is some data stored there even if we got no label
}


// MARK: - MyStreamDeckPlugin

@interface MyStreamDeckPlugin ()

// A timer fired each minute to update the number of unread email from Apple's Mail
//@property (strong) NSTimer *refreshTimer;

// The list of visible contexts
//@property (strong) NSMutableArray *knownContexts;

// The empty post-it icon encoded in base64
@property (strong) NSString *base64PostitEmpty;
@property (strong) NSString *base64PostitSecure;

// The text we want to hold (one entry per key)
@property (strong) NSMutableDictionary *tileText;
@property BOOL dictInitialized;

// The global clipboard
@property NSPasteboard *pboard;

// The timestamp when a key is pressed & when it is released
@property (strong) NSDate *keyPressed;
@property (strong) NSDate *keyReleased;

@end


@implementation MyStreamDeckPlugin



// MARK: - Setup the instance variables if needed

- (void)setupIfNeeded
{
	if (_base64PostitEmpty == nil) {
		_base64PostitEmpty = CreateBase64EncodedString(ComposeImage(GetResourcePath(@"postit-empty@2x.png"), @""));
	}
    if (_base64PostitSecure == nil) {
        _base64PostitSecure = CreateBase64EncodedString(ComposeImage(GetResourcePath(@"postit-secure@2x.png"), @""));
    }

    // Defining we want to use the central clipboard
    _pboard = [NSPasteboard generalPasteboard];
}



// MARK: - Events handler


- (void)keyDownForAction:(NSString *)action withContext:(id)context withPayload:(NSDictionary *)payload forDevice:(NSString *)deviceID
{
    _keyPressed = [[NSDate alloc]init];
}


- (void)keyUpForAction:(NSString *)action withContext:(id)context withPayload:(NSDictionary *)payload forDevice:(NSString *)deviceID
{
    _keyReleased = [[NSDate alloc]init];
    NSTimeInterval diff = [_keyReleased timeIntervalSinceDate:_keyPressed];
    
    // Logging the length of the key press for future reference
    [_connectionManager logMessage: [NSString stringWithFormat:@"[KEY UP] Key pressed for %20lf sec", diff]];
    
    if (diff >= MIN_LONG_PRESS ) {
        
        // Grabbing the current data in the clipboard
        NSString * clipboardContent = [_pboard stringForType:NSStringPboardType];

        NSString * dictKey = keyFromCoord(payload[@"coordinates"]);

        _tileText[dictKey] = clipboardContent;

        // Showing the copy worked
        [_connectionManager showOKForContext:context];
        
        if (diff >= SECURE_PRESS) {
            // Changing the background to convey we have sensitive data there
            [_connectionManager setImage:_base64PostitSecure withContext:context withTarget:kESDSDKTarget_HardwareAndSoftware];
            
            // Adding a safe title to avoid leaking sensitive data
            NSString * secureTitle = askUserForLabel();
            [_connectionManager logMessage:[NSString stringWithFormat:@"We asked the user and got the label (%@)", secureTitle]];
            [_connectionManager setTitle:secureTitle withContext:context withTarget:kESDSDKTarget_HardwareAndSoftware];
        }
        else {
            // Defining everything as image (background + text)
            NSString *backgroundWithText64 = CreateBase64EncodedString(ComposeImage(@"postit-empty@2x.png", _tileText[ keyFromCoord(payload[@"coordinates"]) ]));
            [_connectionManager setImage:backgroundWithText64 withContext:context withTarget:kESDSDKTarget_HardwareAndSoftware];
            
            // THE FOLLOWING WOULD HAVE BEEN A LOT SIMPLER IF ONLY THE SDK SUPPORTED TITLE WRAPPING...
            
            // Changing the background for something simpler to display text over
            //[_connectionManager setImage:_base64PostitEmpty withContext:context withTarget:kESDSDKTarget_HardwareAndSoftware];
            
            // Adding the text to the tile
            //[_connectionManager setTitle:_tileText[ keyFromCoord(payload[@"coordinates"]) ] withContext:context withTarget:kESDSDKTarget_HardwareAndSoftware];
        }
    }
    else {
        [_pboard clearContents];
        BOOL wasClipboardUpdated = [_pboard setString:_tileText[ keyFromCoord(payload[@"coordinates"]) ] forType:NSStringPboardType];
        [_connectionManager logMessage:[NSString stringWithFormat:@"[KEY UP][SHORT PRESS] Text (%@) reinjected back into the clipboard: %hd", _tileText[ keyFromCoord(payload[@"coordinates"]) ], wasClipboardUpdated]];

        if (wasClipboardUpdated) {
            //
            // This code is a big programmatic command+V
            //
            CGKeyCode key = ((CGKeyCode)9); // code for V in qwerty/azerty/qwertz
            
            CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);

            CGEventRef keyDown = CGEventCreateKeyboardEvent(source, key, TRUE);
            CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
            CGEventRef keyUp = CGEventCreateKeyboardEvent(source, key, FALSE);

            CGEventPost(kCGAnnotatedSessionEventTap, keyDown);
            CGEventPost(kCGAnnotatedSessionEventTap, keyUp);

            CFRelease(keyUp);
            CFRelease(keyDown);
            CFRelease(source);
        }
        else {
            [_connectionManager showAlertForContext:context];
        }
    }
    
}

- (void)willAppearForAction:(NSString *)action withContext:(id)context withPayload:(NSDictionary *)payload forDevice:(NSString *)deviceID
{
	// Set up the instance variables if needed
	[self setupIfNeeded];
	
	// Add the context to the list of known contexts
	//[self.knownContexts addObject:context];
}

- (void)willDisappearForAction:(NSString *)action withContext:(id)context withPayload:(NSDictionary *)payload forDevice:(NSString *)deviceID
{
	// Remove the context from the list of known contexts
	//[self.knownContexts removeObject:context];
}

- (void)deviceDidConnect:(NSString *)deviceID withDeviceInfo:(NSDictionary *)deviceInfo
{
    // Relaying the dimensions of the current device as integers
    NSInteger devWidth = [deviceInfo[@"size"][@"rows"] integerValue];
    NSInteger devHeight= [deviceInfo[@"size"][@"columns"] integerValue];
    
    // Preparing our dictionary objects (as we need the device's buttons info)
    _tileText = [[NSMutableDictionary alloc] initWithCapacity: devWidth*devHeight];
    NSMutableDictionary * tmpDict = [[NSMutableDictionary alloc] initWithCapacity:1];
    
	// We need to initialize the dict for text (max the whole size of the device)
    for (NSInteger row=0; row < devWidth; row++) {
        for (NSInteger col=0; col < devHeight; col++) {
            //
            // We need to fake the usual structure we get while running to use the common keyFromCoord() method
            // Unfortunately, a dict requires String or string-like elements so we have to do a formatting :(
            //
            tmpDict[@"row"] = [NSString stringWithFormat:@"%ld", row];
            tmpDict[@"column"] = [NSString stringWithFormat:@"%ld", col];
            _tileText[ keyFromCoord(tmpDict) ] = keyFromCoord(tmpDict);
            // using the key as default value should make any code misbehavior visible
        }
    }
    _dictInitialized = TRUE;
}

- (void)deviceDidDisconnect:(NSString *)deviceID
{
	// Nothing to do
}

- (void)applicationDidLaunch:(NSDictionary *)applicationInfo
{
	// Nothing to do
}

- (void)applicationDidTerminate:(NSDictionary *)applicationInfo
{
	// Nothing to do
}

@end
