//
//  PVGenesisEmulatorCore.m
//  Provenance
//
//  Created by James Addyman on 07/08/2013.
//  Copyright (c) 2013 James Addyman. All rights reserved.
//

#import "PVGenesisEmulatorCore.h"
@import PVSupport;
//#import <PVSupport/OERingBuffer.h>
//#import <PVSupport/DebugUtils.h>
//#import <PVSupport/PVLogging.h>
#import <PVGenesis/libretro.h>
//#import <OpenGLES/EAGL.h>

#if !TARGET_OS_MACCATALYST
#import <OpenGLES/gltypes.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <OpenGLES/EAGL.h>
#else
@import OpenGL;
@import GLUT;
#endif


#include "shared.h"
#include "libretro.h"
#include "state.h"
#include "genesis.h"
#include "md_ntsc.h"
#include "sms_ntsc.h"

@interface PVGenesisEmulatorCore ()
{
    uint32_t *videoBuffer;
    uint32_t *videoBufferA;
    uint32_t *videoBufferB;

	int _videoWidth, _videoHeight;
	int16_t _pad[2][12];
}

@end

__weak PVGenesisEmulatorCore *_current;

@implementation PVGenesisEmulatorCore

static void audio_callback(int16_t left, int16_t right)
{
	__strong PVGenesisEmulatorCore *strongCurrent = _current;
	
	[[strongCurrent ringBufferAtIndex:0] write:&left maxLength:2];
	[[strongCurrent ringBufferAtIndex:0] write:&right maxLength:2];
	
	strongCurrent = nil;
}

static size_t audio_batch_callback(const int16_t *data, size_t frames)
{
	__strong PVGenesisEmulatorCore *strongCurrent = _current;
	
	[[strongCurrent ringBufferAtIndex:0] write:data maxLength:frames << 2];
	
	strongCurrent = nil;
	
	return frames;
}

static void video_callback(const void *data, unsigned width, unsigned height, size_t pitch)
{
	__strong PVGenesisEmulatorCore *strongCurrent = _current;
	
    strongCurrent->_videoWidth  = width;
    strongCurrent->_videoHeight = height;
    
    dispatch_queue_t the_queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
    dispatch_apply(height, the_queue, ^(size_t y){
        const uint32_t *src = (uint32_t*)data + y * (pitch >> 2); //pitch is in bytes not pixels
        uint32_t *dst = strongCurrent->videoBuffer + y * 720;
        
        memcpy(dst, src, sizeof(uint32_t)*width);
    });
	
	strongCurrent = nil;
}

static void input_poll_callback(void)
{
	//DLOG(@"poll callback");
}

static int16_t input_state_callback(unsigned port, unsigned device, unsigned index, unsigned _id)
{
	//DLOG(@"polled input: port: %d device: %d id: %d", port, device, id);
	
	__strong PVGenesisEmulatorCore *strongCurrent = _current;
    int16_t value = 0;

    if (port == 0 & device == RETRO_DEVICE_JOYPAD)
	{
        if (strongCurrent.controller1)
        {
            value = [strongCurrent controllerValueForButtonID:_id forPlayer:port];
        }

        if (value == 0)
        {
            value = strongCurrent->_pad[0][_id];
        }
	}
	else if(port == 1 & device == RETRO_DEVICE_JOYPAD)
	{
        if (strongCurrent.controller2)
        {
            value = [strongCurrent controllerValueForButtonID:_id forPlayer:port];
        }

        if (value == 0)
        {
            value = strongCurrent->_pad[1][_id];
        }
	}
	
	strongCurrent = nil;
	
	return value;
}

static bool environment_callback(unsigned cmd, void *data)
{
    __strong PVGenesisEmulatorCore *strongCurrent = _current;
    
	switch(cmd)
	{
		case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY :
		{
			NSString *appSupportPath = [strongCurrent BIOSPath];
			
			*(const char **)data = [appSupportPath UTF8String];
			DLOG(@"Environ SYSTEM_DIRECTORY: \"%@\".\n", appSupportPath);
			break;
		}
		case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
		{
			break;
		}
		default :
			DLOG(@"Environ UNSUPPORTED (#%u).\n", cmd);
			return false;
	}
	
    strongCurrent = nil;
    
	return true;
}

- (id)init {
	if ((self = [super init])) {
	videoBufferA = (uint32_t *)malloc(720 * 576 * sizeof(uint32_t));
        videoBufferB = (uint32_t *)malloc(720 * 576 * sizeof(uint32_t));
	}
	
	_current = self;
	
	return self;
}

- (void)dealloc {
    free(videoBufferA);
    videoBufferA = NULL;
    free(videoBufferB);
    videoBufferB = NULL;
    videoBuffer = NULL;
}

#pragma mark - Execution

- (void)resetEmulation
{
	retro_reset();
}

- (void)stopEmulation
{
	if ([self.batterySavesPath length])
	{
		[[NSFileManager defaultManager] createDirectoryAtPath:self.batterySavesPath withIntermediateDirectories:YES attributes:nil error:NULL];
		NSString *filePath = [self.batterySavesPath stringByAppendingPathComponent:[self.romName stringByAppendingPathExtension:@"sav"]];
		[self writeSaveFile:filePath forType:RETRO_MEMORY_SAVE_RAM];
    }

	[super stopEmulation];
	
	double delayInSeconds = 0.1;
	dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
	dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
		retro_unload_game();
		retro_deinit();
	});
}

- (void)executeFrame {
    int aud;
    
    if (system_hw == SYSTEM_MCD)
        system_frame_scd(0);
    else if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
        system_frame_gen(0);
    else
        system_frame_sms(0);
    
    video_callback(bitmap.data, bitmap.viewport.w + (bitmap.viewport.x * 2), bitmap.viewport.h + (bitmap.viewport.y * 2), bitmap.pitch);
    
    aud = audio_update(soundbuffer) << 1;
    audio_batch_callback(soundbuffer, aud >> 1);
}

- (void)executeFrameSkippingFrame:(BOOL)skip {
    //int aud;
    
//    int skipI = skip ? 1 : 0;
    
    if (system_hw == SYSTEM_MCD)
        system_frame_scd(0);
    else if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
        system_frame_gen(0);
    else
        system_frame_sms(0);
    
    video_callback(bitmap.data, bitmap.viewport.w + (bitmap.viewport.x * 2), bitmap.viewport.h + (bitmap.viewport.y * 2), bitmap.pitch);
    
    int aud = audio_update(soundbuffer) << 1;
    audio_batch_callback(soundbuffer, aud >> 1);
}

- (BOOL)loadFileAtPath:(NSString*)path error:(NSError**)error
{
	memset(_pad, 0, sizeof(int16_t) * 10);
    
    const void *data;
    size_t size;
    self.romName = [[[path lastPathComponent] componentsSeparatedByString:@"."] objectAtIndex:0];
    
    //load cart, read bytes, get length
    NSData* dataObj = [NSData dataWithContentsOfFile:[path stringByStandardizingPath]];
    if (dataObj == nil)
	{
		if(error != NULL) {
			NSDictionary *userInfo = @{
									   NSLocalizedDescriptionKey: @"Failed to load game.",
									   NSLocalizedFailureReasonErrorKey: @"File was unreadble.",
									   NSLocalizedRecoverySuggestionErrorKey: @"Check the file isn't corrupt and exists."
									   };

			NSError *newError = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
													code:PVEmulatorCoreErrorCodeCouldNotLoadRom
												userInfo:userInfo];

			*error = newError;
		}
		return false;
	}
    size = [dataObj length];
    data = (uint8_t*)[dataObj bytes];
    const char *meta = NULL;
    
    if (videoBufferA) {
        free(videoBufferA);
    }
    videoBufferA = NULL;
    
    if (videoBufferB) {
        free(videoBufferB);
    }
    videoBufferB = NULL;
    
    videoBuffer = NULL;
    
    videoBufferA = (uint8_t *)malloc(720 * 576 * sizeof(uint32_t));
    videoBufferB = (uint8_t *)malloc(720 * 576 * sizeof(uint32_t));
    
    bitmap.data = (uint8_t *)videoBufferA;
    videoBuffer = videoBufferB;
    
    retro_set_environment(environment_callback);
	retro_init();
	
    retro_set_audio_sample(audio_callback);
    retro_set_audio_sample_batch(audio_batch_callback);
    retro_set_video_refresh(video_callback);
    retro_set_input_poll(input_poll_callback);
    retro_set_input_state(input_state_callback);
    
    const char *fullPath = [path UTF8String];
    
    struct retro_game_info info = {NULL};
    info.path = fullPath;
    info.data = data;
    info.size = size;
    info.meta = meta;
    
    if (retro_load_game(&info))
    {
        if ([self.batterySavesPath length])
        {
            [[NSFileManager defaultManager] createDirectoryAtPath:self.batterySavesPath withIntermediateDirectories:YES attributes:nil error:NULL];
            
            NSString *filePath = [self.batterySavesPath stringByAppendingPathComponent:[self.romName stringByAppendingPathExtension:@"sav"]];
            
            [self loadSaveFile:filePath forType:RETRO_MEMORY_SAVE_RAM];
        }
        
        struct retro_system_av_info info;
        retro_get_system_av_info(&info);
        
        _frameInterval = info.timing.fps;
        _sampleRate = info.timing.sample_rate;
        
        retro_get_region();
        [self executeFrame];
        
        return YES;
    }

	if(error != NULL) {
		NSDictionary *userInfo = @{
								   NSLocalizedDescriptionKey: @"Failed to load game.",
								   NSLocalizedFailureReasonErrorKey: @"GenPlusGX failed to load game.",
								   NSLocalizedRecoverySuggestionErrorKey: @"Check the file isn't corrupt and supported GenPlusGX ROM format."
								   };

		NSError *newError = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
												code:PVEmulatorCoreErrorCodeCouldNotLoadRom
											userInfo:userInfo];

		*error = newError;
	}

    return NO;
}

- (void)loadSaveFile:(NSString *)path forType:(int)type
{
    size_t size = retro_get_memory_size(type);
    void *ramData = retro_get_memory_data(type);
    
    if (size == 0 || !ramData)
    {
        return;
    }
    
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || ![data length])
    {
        WLOG(@"Couldn't load save file.");
    }
    
    [data getBytes:ramData length:size];
}

- (BOOL)writeSaveFile:(NSString *)path forType:(int)type
{
    size_t size = retro_get_memory_size(type);
    void *ramData = retro_get_memory_data(type);
    
    if (ramData && (size > 0))
    {
        retro_serialize(ramData, size);
        NSData *data = [NSData dataWithBytes:ramData length:size];
        BOOL success = [data writeToFile:path atomically:YES];
        if (!success)
        {
            ELOG(@"Error writing save file");
        }
		return success;
	} else {
		return NO;
	}
}

#pragma mark - Video

- (void)swapBuffers
{
    if (bitmap.data == (uint8_t*)videoBufferA)
    {
        videoBuffer = videoBufferA;
        bitmap.data = (uint8_t*)videoBufferB;
    }
    else
    {
        videoBuffer = videoBufferB;
        bitmap.data = (uint8_t*)videoBufferA;
    }
}

- (const void *)videoBuffer
{
    return videoBuffer;
}

-(BOOL)isDoubleBuffered {
    return YES;
}

- (CGRect)screenRect
{
    if([[self systemIdentifier] isEqualToString:@"com.provenance.gamegear"])
    {
        return CGRectMake(0, 0, 160, 144);
    }
    else
    {
        return CGRectMake(0, 0, _videoWidth, _videoHeight);
    }
}

- (CGSize)aspectSize
{
    if([[self systemIdentifier] isEqualToString:@"com.provenance.gamegear"])
    {
        return CGSizeMake(160, 144);
    }
    else if([[self systemIdentifier] isEqualToString:@"com.provenance.mastersystem"] || [[self systemIdentifier] isEqualToString:@"com.provenance.sg1000"])
    {
        return CGSizeMake(256 * (8.0/7.0), 192);
    }
    else // is Genesis/Megadrive
    {
        return CGSizeMake(_videoWidth, _videoHeight);
    }
}

- (CGSize)bufferSize
{
	return CGSizeMake(720, 576);
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_BYTE;
}

- (GLenum)internalPixelFormat
{
    return GL_RGBA;
}

- (NSTimeInterval)frameInterval
{
    return _frameInterval; // ? _frameInterval : 59.92;
}

#pragma mark - Audio

- (double)audioSampleRate
{
	return _sampleRate ? _sampleRate : 44100;
}

- (NSUInteger)channelCount
{
    return 2;
}

#pragma mark - Input

- (void)didPushGenesisButton:(PVGenesisButton)button forPlayer:(NSInteger)player
{
	_pad[player][button] = 1;
}

- (void)didReleaseGenesisButton:(PVGenesisButton)button forPlayer:(NSInteger)player
{
	_pad[player][button] = 0;
}

- (NSInteger)controllerValueForButtonID:(unsigned)buttonID forPlayer:(NSInteger)player
{
    GCController *controller = nil;

    if (player == 0)
    {
        controller = self.controller1;
    }
    else
    {
        controller = self.controller2;
    }

    // Sega SG-1000…
    if ([[self systemIdentifier] isEqualToString:@"com.provenance.sg1000"]) {
        
        if ([controller extendedGamepad]) {
            GCExtendedGamepad *gamepad = [controller extendedGamepad];
            GCControllerDirectionPad *dpad = [gamepad dpad];
            switch (buttonID) {
                case PVGenesisButtonUp:
                    return [[dpad up] isPressed]?:[[[gamepad leftThumbstick] up] isPressed];
                case PVGenesisButtonDown:
                    return [[dpad down] isPressed]?:[[[gamepad leftThumbstick] down] isPressed];
                case PVGenesisButtonLeft:
                    return [[dpad left] isPressed]?:[[[gamepad leftThumbstick] left] isPressed];
                case PVGenesisButtonRight:
                    return [[dpad right] isPressed]?:[[[gamepad leftThumbstick] right] isPressed];
                case PVGenesisButtonB: // SG1000 ButtonL/1
                    return [[gamepad buttonA] isPressed]?:[[gamepad buttonY] isPressed]?:[[gamepad leftShoulder] isPressed]?:[[gamepad leftTrigger] isPressed];
                case PVGenesisButtonC: // SG1000 ButtonR/2
                    return [[gamepad buttonB] isPressed]?:[[gamepad buttonX] isPressed]?:[[gamepad rightShoulder] isPressed]?:[[gamepad rightTrigger] isPressed];
                default:
                    break;
            }
            
        } else if ([controller gamepad]) {
            GCGamepad *gamepad = [controller gamepad];
            GCControllerDirectionPad *dpad = [gamepad dpad];
            switch (buttonID) {
                case PVGenesisButtonUp:
                    return [[dpad up] isPressed];
                case PVGenesisButtonDown:
                    return [[dpad down] isPressed];
                case PVGenesisButtonLeft:
                    return [[dpad left] isPressed];
                case PVGenesisButtonRight:
                    return [[dpad right] isPressed];
                case PVGenesisButtonB: // SG1000 ButtonL/1
                    return [[gamepad buttonA] isPressed]?:[[gamepad buttonY] isPressed]?:[[gamepad leftShoulder] isPressed];
                case PVGenesisButtonC: // SG1000 ButtonR/2
                    return [[gamepad buttonB] isPressed]?:[[gamepad buttonX] isPressed]?:[[gamepad rightShoulder] isPressed];
                default:
                    break;
            }
        }
        
#if TARGET_OS_TV

        else if ([controller microGamepad]) {
            GCMicroGamepad *gamepad = [controller microGamepad];
            GCControllerDirectionPad *dpad = [gamepad dpad];
            switch (buttonID) {
                case PVGenesisButtonUp:
                    return [[dpad up] value] > 0.5;
                    break;
                case PVGenesisButtonDown:
                    return [[dpad down] value] > 0.5;
                    break;
                case PVGenesisButtonLeft:
                    return [[dpad left] value] > 0.5;
                    break;
                case PVGenesisButtonRight:
                    return [[dpad right] value] > 0.5;
                    break;
                case PVGenesisButtonB: // SG1000 ButtonL/1
                    return [[gamepad buttonA] isPressed];
                    break;
                case PVGenesisButtonC: // SG1000 ButtonR/2
                    return [[gamepad buttonX] isPressed];
                    break;
                default:
                    break;
            }
        }
        
#endif
        
    // Sega Master System…
    } else if ([[self systemIdentifier] isEqualToString:@"com.provenance.mastersystem"]) {
       
       if ([controller extendedGamepad]) {
           GCExtendedGamepad *gamepad = [controller extendedGamepad];
           GCControllerDirectionPad *dpad = [gamepad dpad];
           switch (buttonID) {
               case PVGenesisButtonUp:
                   return [[dpad up] isPressed]?:[[[gamepad leftThumbstick] up] isPressed];
               case PVGenesisButtonDown:
                   return [[dpad down] isPressed]?:[[[gamepad leftThumbstick] down] isPressed];
               case PVGenesisButtonLeft:
                   return [[dpad left] isPressed]?:[[[gamepad leftThumbstick] left] isPressed];
               case PVGenesisButtonRight:
                   return [[dpad right] isPressed]?:[[[gamepad leftThumbstick] right] isPressed];
               case PVGenesisButtonB: // Button1
                   return [[gamepad buttonA] isPressed]?:[[gamepad buttonY] isPressed]?:[[gamepad rightShoulder] isPressed]?:[[gamepad rightTrigger] isPressed];
               case PVGenesisButtonC: // Button2
                   return [[gamepad buttonB] isPressed]?:[[gamepad buttonX] isPressed]?:[[gamepad leftTrigger] isPressed];
               case PVGenesisButtonStart: // MS Pause
                   return [[gamepad leftShoulder] isPressed];
               default:
                   break;
           }
           
       } else if ([controller gamepad]) {
           
           GCGamepad *gamepad = [controller gamepad];
           GCControllerDirectionPad *dpad = [gamepad dpad];
           switch (buttonID) {
               case PVGenesisButtonUp:
                   return [[dpad up] isPressed];
               case PVGenesisButtonDown:
                   return [[dpad down] isPressed];
               case PVGenesisButtonLeft:
                   return [[dpad left] isPressed];
               case PVGenesisButtonRight:
                   return [[dpad right] isPressed];
               case PVGenesisButtonB: // Button1
                   return [[gamepad buttonA] isPressed]?:[[gamepad buttonY] isPressed]?:[[gamepad rightShoulder] isPressed];
               case PVGenesisButtonC: // Button2
                   return [[gamepad buttonB] isPressed]?:[[gamepad buttonX] isPressed];
               case PVGenesisButtonStart: // MS Pause
                   return [[gamepad leftShoulder] isPressed];
               default:
                   break;
           }
       }
       
#if TARGET_OS_TV

       else if ([controller microGamepad]) {
           GCMicroGamepad *gamepad = [controller microGamepad];
           GCControllerDirectionPad *dpad = [gamepad dpad];
           switch (buttonID) {
               case PVGenesisButtonUp:
                   return [[dpad up] value] > 0.5;
                   break;
               case PVGenesisButtonDown:
                   return [[dpad down] value] > 0.5;
                   break;
               case PVGenesisButtonLeft:
                   return [[dpad left] value] > 0.5;
                   break;
               case PVGenesisButtonRight:
                   return [[dpad right] value] > 0.5;
                   break;
               case PVGenesisButtonB: // Button1
                   return [[gamepad buttonA] isPressed];
                   break;
               case PVGenesisButtonC: // Button2
                   return [[gamepad buttonX] isPressed];
                   break;
               default:
                   break;
           }
       }
           
#endif
    
        // Game Gear…
    } else if ([[self systemIdentifier] isEqualToString:@"com.provenance.gamegear"]) {
        
        if ([controller extendedGamepad]) {
            GCExtendedGamepad *gamepad = [controller extendedGamepad];
            GCControllerDirectionPad *dpad = [gamepad dpad];
            switch (buttonID) {
                case PVGenesisButtonUp:
                    return [[dpad up] isPressed]?:[[[gamepad leftThumbstick] up] isPressed];
                case PVGenesisButtonDown:
                    return [[dpad down] isPressed]?:[[[gamepad leftThumbstick] down] isPressed];
                case PVGenesisButtonLeft:
                    return [[dpad left] isPressed]?:[[[gamepad leftThumbstick] left] isPressed];
                case PVGenesisButtonRight:
                    return [[dpad right] isPressed]?:[[[gamepad leftThumbstick] right] isPressed];
                case PVGenesisButtonB: // Button1
                    return [[gamepad buttonA] isPressed]?:[[gamepad buttonY] isPressed];
                case PVGenesisButtonC: // Button2
                    return [[gamepad buttonB] isPressed]?:[[gamepad buttonX] isPressed];
                case PVGenesisButtonStart: // GG Start
                    return [[gamepad rightShoulder] isPressed]?:[[gamepad rightTrigger] isPressed];
                default:
                    break;
            }
            
        } else if ([controller gamepad]) {
            
            GCGamepad *gamepad = [controller gamepad];
            GCControllerDirectionPad *dpad = [gamepad dpad];
            switch (buttonID) {
                case PVGenesisButtonUp:
                    return [[dpad up] isPressed];
                case PVGenesisButtonDown:
                    return [[dpad down] isPressed];
                case PVGenesisButtonLeft:
                    return [[dpad left] isPressed];
                case PVGenesisButtonRight:
                    return [[dpad right] isPressed];
                case PVGenesisButtonB: // Button1
                    return [[gamepad buttonA] isPressed]?:[[gamepad buttonY] isPressed];
                case PVGenesisButtonC: // Button2
                    return [[gamepad buttonB] isPressed]?:[[gamepad buttonX] isPressed];
                case PVGenesisButtonStart: // GG Start
                    return [[gamepad rightShoulder] isPressed];
                default:
                    break;
            }
        }
        
#if TARGET_OS_TV
        
        else if ([controller microGamepad]) {
            GCMicroGamepad *gamepad = [controller microGamepad];
            GCControllerDirectionPad *dpad = [gamepad dpad];
            switch (buttonID) {
                case PVGenesisButtonUp:
                    return [[dpad up] value] > 0.5;
                    break;
                case PVGenesisButtonDown:
                    return [[dpad down] value] > 0.5;
                    break;
                case PVGenesisButtonLeft:
                    return [[dpad left] value] > 0.5;
                    break;
                case PVGenesisButtonRight:
                    return [[dpad right] value] > 0.5;
                    break;
                case PVGenesisButtonB: // Button1
                    return [[gamepad buttonA] isPressed];
                    break;
                case PVGenesisButtonC: // Button2
                    return [[gamepad buttonX] isPressed];
                    break;
                default:
                    break;
            }
        }
        
#endif
        
    // Sega Genesis/Mega Drive, Sega/Mega CD, 32X…
    } else {
       
        if ([controller extendedGamepad]) {
            GCExtendedGamepad *gamepad = [controller extendedGamepad];
            GCControllerDirectionPad *dpad = [gamepad dpad];
            if (PVSettingsModel.shared.use8BitdoM30) // Maps the Sega Controls to the 8BitDo M30 if enabled in Settings / Controller
            {switch (buttonID) {
                case PVGenesisButtonUp:
                    return [[[gamepad leftThumbstick] up] value] > 0.1;
                case PVGenesisButtonDown:
                    return [[[gamepad leftThumbstick] down] value] > 0.1;
                case PVGenesisButtonLeft:
                    return [[[gamepad leftThumbstick] left] value] > 0.1;
                case PVGenesisButtonRight:
                    return [[[gamepad leftThumbstick] right] value] > 0.1;
                case PVGenesisButtonA:
                    return [[gamepad buttonA] isPressed];
                case PVGenesisButtonB:
                    return [[gamepad buttonB] isPressed];
                case PVGenesisButtonC:
                    return [[gamepad rightShoulder] isPressed];
                case PVGenesisButtonX:
                    return [[gamepad buttonX] isPressed];
                case PVGenesisButtonY:
                    return [[gamepad buttonY] isPressed];
                case PVGenesisButtonZ:
                    return [[gamepad leftShoulder] isPressed];
                case PVGenesisButtonMode:
                    return [[gamepad buttonOptions] isPressed];
                case PVGenesisButtonStart:
#if TARGET_OS_TV
                    return [[gamepad buttonMenu] isPressed];
#else
                    return [[gamepad rightTrigger] isPressed];
#endif
                default:
                    break;
            }}
            { switch (buttonID) {
                case PVGenesisButtonUp:
                    return [[dpad up] isPressed]?:[[[gamepad leftThumbstick] up] isPressed];
                case PVGenesisButtonDown:
                    return [[dpad down] isPressed]?:[[[gamepad leftThumbstick] down] isPressed];
                case PVGenesisButtonLeft:
                    return [[dpad left] isPressed]?:[[[gamepad leftThumbstick] left] isPressed];
                case PVGenesisButtonRight:
                    return [[dpad right] isPressed]?:[[[gamepad leftThumbstick] right] isPressed];
                case PVGenesisButtonA:
                    return [[gamepad buttonX] isPressed];
                case PVGenesisButtonB:
                    return [[gamepad buttonA] isPressed];
                case PVGenesisButtonC:
                    return [[gamepad buttonB] isPressed];
                case PVGenesisButtonX:
                    return [[gamepad leftShoulder] isPressed];
                case PVGenesisButtonY:
                    return [[gamepad buttonY] isPressed];
                case PVGenesisButtonZ:
                    return [[gamepad rightShoulder] isPressed];
                case PVGenesisButtonMode:
                    return [[gamepad leftTrigger] isPressed];
                case PVGenesisButtonStart:
                    return [[gamepad rightTrigger] isPressed];
                default:
                   break;
            }}
            
        } else if ([controller gamepad]) {
            GCGamepad *gamepad = [controller gamepad];
            GCControllerDirectionPad *dpad = [gamepad dpad];
            switch (buttonID) {
                case PVGenesisButtonUp:
                    return [[dpad up] isPressed];
                case PVGenesisButtonDown:
                    return [[dpad down] isPressed];
                case PVGenesisButtonLeft:
                    return [[dpad left] isPressed];
                case PVGenesisButtonRight:
                    return [[dpad right] isPressed];
                case PVGenesisButtonA:
                    return [[gamepad buttonX] isPressed];
                case PVGenesisButtonB:
                    return [[gamepad buttonA] isPressed];
                case PVGenesisButtonC:
                    return [[gamepad buttonB] isPressed];
                case PVGenesisButtonX:
                    return [[gamepad leftShoulder] isPressed];
                case PVGenesisButtonY:
                    return [[gamepad buttonY] isPressed];
                case PVGenesisButtonZ:
                    return [[gamepad rightShoulder] isPressed];
                default:
                    break;
            }
        }
        
#if TARGET_OS_TV
        
        else if ([controller microGamepad]) {
            GCMicroGamepad *gamepad = [controller microGamepad];
            GCControllerDirectionPad *dpad = [gamepad dpad];
            switch (buttonID) {
                case PVGenesisButtonUp:
                    return [[dpad up] value] > 0.5;
                    break;
                case PVGenesisButtonDown:
                    return [[dpad down] value] > 0.5;
                    break;
                case PVGenesisButtonLeft:
                    return [[dpad left] value] > 0.5;
                    break;
                case PVGenesisButtonRight:
                    return [[dpad right] value] > 0.5;
                    break;
                case PVGenesisButtonA:
                    return [[gamepad buttonA] isPressed];
                    break;
                case PVGenesisButtonB:
                    return [[gamepad buttonX] isPressed];
                    break;
                default:
                    break;
            }
        }
        
  #endif
        
    }
  
    
    return 0;
}

#pragma mark - State Saving

- (BOOL)saveStateToFileAtPath:(NSString *)path error:(NSError *__autoreleasing *)error
{
    @synchronized(self) {
        int serial_size = retro_serialize_size();
        uint8_t *serial_data = (uint8_t *) malloc(serial_size);
        
        retro_serialize(serial_data, serial_size);
        
        NSError *error = nil;
        NSData *saveStateData = [NSData dataWithBytes:serial_data length:serial_size];
        free(serial_data);
        BOOL success = [saveStateData writeToFile:path
                                          options:NSDataWritingAtomic
                                            error:&error];
        if (!success) {
            ELOG(@"Error saving state: %@", [error localizedDescription]);
            return NO;
        }
        
        return YES;
    }
}

- (BOOL)loadStateFromFileAtPath:(NSString *)path error:(NSError *__autoreleasing *)error
{
    @synchronized(self) {
        NSData *saveStateData = [NSData dataWithContentsOfFile:path];
        if (!saveStateData)
        {
			if(error != NULL) {
				NSDictionary *userInfo = @{
										   NSLocalizedDescriptionKey: @"Failed to load save state.",
										   NSLocalizedFailureReasonErrorKey: @"Genesis failed to read savestate data.",
										   NSLocalizedRecoverySuggestionErrorKey: @"Check that the path is correct and file exists."
										   };

				NSError *newError = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
														code:PVEmulatorCoreErrorCodeCouldNotLoadState
													userInfo:userInfo];
				*error = newError;
			}
            ELOG(@"Unable to load save state from path: %@", path);
            return NO;
        }
        
        if (!retro_unserialize([saveStateData bytes], [saveStateData length]))
        {
			if(error != NULL) {
				NSDictionary *userInfo = @{
					NSLocalizedDescriptionKey: @"Failed to load save state.",
					NSLocalizedFailureReasonErrorKey: @"Genesis failed to load savestate data.",
					NSLocalizedRecoverySuggestionErrorKey: @"Check that the path is correct and file exists."
				};

				NSError *newError = [NSError errorWithDomain:PVEmulatorCoreErrorDomain
														code:PVEmulatorCoreErrorCodeCouldNotLoadState
													userInfo:userInfo];
				*error = newError;
			}
            DLOG(@"Unable to load save state");
            return NO;
        }
        
        return YES;
    }
}

@end
