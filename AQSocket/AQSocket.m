//
//  AQSocket.m
//  AQSocket
//
//  Created by Jim Dovey on 11-12-16.
//  Copyright (c) 2011 Jim Dovey. All rights reserved.
//  
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions
//  are met:
//  
//  Redistributions of source code must retain the above copyright notice,
//  this list of conditions and the following disclaimer.
//  
//  Redistributions in binary form must reproduce the above copyright
//  notice, this list of conditions and the following disclaimer in the
//  documentation and/or other materials provided with the distribution.
//  
//  Neither the name of the project's author nor the names of its
//  contributors may be used to endorse or promote products derived from
//  this software without specific prior written permission.
//  
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
//  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
//  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
//  FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
//  HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
//  TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
//  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
//  LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
//  NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "AQSocket.h"
#import "AQSocketReader.h"
#import "AQSocketReader+PrivateInternal.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <syslog.h>

// See -connectToAddress:port:error: for discussion.
#if TARGET_OS_IPHONE
#import <UIKit/UIApplication.h>
#else
#import <AppKit/NSApplication.h>
#endif

#define USING_MRR (!__has_feature(objc_arc))

// A sly little NSData class simplifying the dispatch_data_t -> NSData transition.
@interface _AQDispatchData : NSData
{
    dispatch_data_t _ddata;
    const void *    _buf;
    size_t          _len;
}
- (id) initWithDispatchData: (dispatch_data_t) ddata;
@end

@implementation _AQDispatchData

- (id) initWithDispatchData: (dispatch_data_t) ddata
{
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    // First off, ensure we have a contiguous range of bytes to deal with.
    ddata = dispatch_data_create_map(ddata, (void *)_buf, &_len);
    
    // Retain the dispatch data object to keep the underlying bytes in memory.
    dispatch_retain(ddata);
    _ddata = ddata;
    
    return ( self );
}

- (void) dealloc
{
    if ( _ddata != NULL )
        dispatch_release(_ddata);
#if USING_MRR
    [super dealloc];
#endif
}

- (const void *) bytes
{
    return ( _buf );
}

- (NSUInteger) length
{
    return ( _len );
}

@end

#pragma mark -

@interface AQSocket (CFSocketConnectionCallback)
- (void) connectedSuccessfully;
- (void) connectionFailedWithError: (SInt32) err;
@end

static void _CFSocketConnectionCallBack(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    if ( type != kCFSocketConnectCallBack )
        return;
    
    AQSocket * aqsock = (__bridge AQSocket *)info;
    if ( data == NULL )
        [aqsock connectedSuccessfully];
    else
        [aqsock connectionFailedWithError: *((SInt32 *)data)];
}

static BOOL _SocketAddressFromString(NSString * addrStr, BOOL isNumeric, UInt16 port, struct sockaddr_storage * outAddr, NSError * __autoreleasing* outError)
{
    // Flags for getaddrinfo():
    //
    // `AI_ADDRCONFIG`: Only return IPv4 or IPv6 if the local host has configured
    // interfaces for those types.
    //
    // `AI_V4MAPPED`: If no IPv6 addresses found, return an IPv4-mapped IPv6
    // address for any IPv4 addresses found.
    int flags = AI_ADDRCONFIG|AI_V4MAPPED;
    
    // If providing a numeric IPv4 or IPv6 string, tell getaddrinfo() not to
    // do DNS name lookup.
    if ( isNumeric )
        flags |= AI_NUMERICHOST;
    
    // We're assuming TCP at this point
    struct addrinfo hints = {
        .ai_flags = flags,
        .ai_family = AF_INET6,       // using AF_INET6 with 4to6 support
        .ai_socktype = SOCK_STREAM,
        .ai_protocol = IPPROTO_TCP
    };
    
    struct addrinfo *pLookup = NULL;
    
    // Hrm-- this is synchronous, which is required since we can't init asynchronously
    int err = getaddrinfo([addrStr UTF8String], NULL, &hints, &pLookup);
    if ( err != 0 )
    {
        NSLog(@"Error from getaddrinfo() for address %@: %s", addrStr, gai_strerror(err));
        if ( outError != NULL )
        {
            NSDictionary * userInfo = [[NSDictionary alloc] initWithObjectsAndKeys: [NSString stringWithUTF8String: gai_strerror(err)], NSLocalizedDescriptionKey, nil];
            *outError = [NSError errorWithDomain: @"GetAddrInfoErrorDomain" code: err userInfo: userInfo];
#if USING_MRR
            [userInfo release];
#endif
        }
        
        return ( NO );
    }
    
    // Copy the returned address to the output parameter
    memcpy(outAddr, pLookup->ai_addr, pLookup->ai_addr->sa_len);
    
    switch ( outAddr->ss_family )
    {
        case AF_INET:
        {
            struct sockaddr_in *p = (struct sockaddr_in *)outAddr;
            p->sin_port = htons(port);  // remember to put in network byte-order!
            break;
        }
        case AF_INET6:
        {
            struct sockaddr_in6 *p = (struct sockaddr_in6 *)outAddr;
            p->sin6_port = htons(port); // network byte order again
            break;
        }
        default:
            return ( NO );
    }
    
    // Have to release the returned address information here
    freeaddrinfo(pLookup);
    return ( 0 );
}

#pragma mark -

@implementation AQSocket
{
    int                 _socketType;
    int                 _socketProtocol;
    CFSocketRef         _socketRef;
    CFRunLoopSourceRef  _socketRunloopSource;
    dispatch_io_t       _socketIO;
    AQSocketReader *    _socketReader;
    dispatch_source_t   _readWatcher;
}

@synthesize eventHandler;

- (id) initWithSocketType: (int) type
{
    NSParameterAssert(type == SOCK_STREAM || type == SOCK_DGRAM);
    self = [super init];
    if ( self == nil )
        return ( nil );
    
    _socketType = type;
    _socketProtocol = (type == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP);
    
    return ( self );
}

- (id) init
{
    return ( [self initWithSocketType: SOCK_STREAM] );
}

- (void) dealloc
{
    if ( _readWatcher != NULL )
    {
        dispatch_source_cancel(_readWatcher);
        dispatch_release(_readWatcher);
    }
    if ( _socketIO != NULL )
    {
        // Closing the socket IO also releases _socketRef
        dispatch_io_close(_socketIO, DISPATCH_IO_STOP);
        dispatch_release(_socketIO);
    }
    else if ( _socketRef != NULL )
    {
        // Not got around to initializing the dispatch IO channel yet,
        // so we will have to release the socket ref manually.
        CFRelease(_socketRef);
    }
    if ( _socketRunloopSource != NULL )
    {
        // Ensure the source is no longer scheduled in any run loops.
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _socketRunloopSource, kCFRunLoopDefaultMode);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _socketRunloopSource, (__bridge CFStringRef)
#if TARGET_OS_IPHONE
                              UITrackingRunLoopMode
#else
                              NSEventTrackingRunLoopMode
#endif
                              );
        
        // Now we can safely release our reference to it.
        CFRelease(_socketRunloopSource);
    }
#if USING_MRR
    [_socketReader release];
#endif
}

- (BOOL) connectToAddress: (struct sockaddr *) saddr
                    error: (NSError **) error
{
    // We're only initializing this member once we successfully connect
    if ( _socketIO != nil )
    {
        if ( error != NULL )
        {
            NSDictionary * info = [[NSDictionary alloc] initWithObjectsAndKeys: NSLocalizedString(@"Already connected.", @"Connection error"), NSLocalizedDescriptionKey, nil];
            *error = [NSError errorWithDomain: NSCocoaErrorDomain code: 1 userInfo: info];
#if USING_MRR
            [info release];
#endif
        }
        
        return ( NO );
    }
    
    // We require that an event handler be set, so we can notify
    // connection success
    if ( self.eventHandler == NULL )
    {
        if ( error != NULL )
        {
            NSDictionary * info = [[NSDictionary alloc] initWithObjectsAndKeys: NSLocalizedString(@"No event handler provided.", @"Connection error"), NSLocalizedDescriptionKey, nil];
            *error = [NSError errorWithDomain: NSCocoaErrorDomain code: 2 userInfo: info];
#if USING_MRR
            [info release];
#endif
        }
        
        return ( NO );
    }
    
    // Create the socket with the appropriate socket family from the address
    // structure.
    CFSocketContext ctx = {
        .version = 0,
        .info = (__bridge void *)self,  // just a plain bridge cast
        .retain = CFRetain,
        .release = CFRelease,
        .copyDescription = CFCopyDescription
    };
    
    _socketRef = CFSocketCreate(kCFAllocatorDefault, saddr->sa_family, _socketType, _socketProtocol, kCFSocketConnectCallBack, _CFSocketConnectionCallBack, &ctx);
    if ( _socketRef == NULL )
    {
        // We failed to create the socket, so build an error (if appropriate)
        // and return `NO`.
        if ( error != NULL )
        {
            // This error code is -1004.
            *error = [NSError errorWithDomain: NSURLErrorDomain code: NSURLErrorCannotConnectToHost userInfo: nil];
        }
        
        return ( NO );
    }
    
    // Create a runloop source for the socket reference and bind it to a
    // runloop that's guaranteed to be running some time in the future: the main
    // one.
    _socketRunloopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socketRef, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _socketRunloopSource, kCFRunLoopDefaultMode);
    
    // We also want to ensure that the connection callback fires during
    // input event tracking. There are different constants for this on iOS and
    // OS X, so I've used a compiler switch for that.
    CFRunLoopAddSource(CFRunLoopGetMain(), _socketRunloopSource, (__bridge CFStringRef)
#if TARGET_OS_IPHONE
                       UITrackingRunLoopMode
#else
                       NSEventTrackingRunLoopMode
#endif
                       );
    
    // Start the connection process.
    // Let's fire off the connection attempt and wait for the socket to become
    // readable, which means the connection succeeded. The timeout value of
    // -1 means 'do it in the background', meaning our C callback will be invoked
    // when the connection attempt succeeds or fails.
    // Note that in this instance I'm using a plain __bridge cast for `data`, so
    // that no retain/release operations or change of ownership is implied.
    NSData * data = [[NSData alloc] initWithBytesNoCopy: saddr
                                                 length: saddr->sa_len
                                           freeWhenDone: NO];
    CFSocketError err = CFSocketConnectToAddress(_socketRef, (__bridge CFDataRef)data, -1);
#if USING_MRR
    [data release];
#endif
    
    if ( err != kCFSocketSuccess )
    {
        NSLog(@"Error connecting socket: %ld", err);
        
        if ( error != NULL )
        {
            if ( err == kCFSocketError )
            {
                // Try to get hold of the underlying error from the raw socket.
                int sockerr = 0;
                socklen_t len = sizeof(sockerr);
                if ( getsockopt(CFSocketGetNative(_socketRef), SOL_SOCKET, SO_ERROR, &sockerr, &len) == -1 )
                {
                    // Yes, this is cheating.
                    sockerr = errno;
                }
                
                // The CoreFoundation CFErrorRef (toll-free-bridged with NSError)
                // actually fills in the userInfo for POSIX errors from a
                // localized table. Neat, huh?
                *error = [NSError errorWithDomain: NSPOSIXErrorDomain code: sockerr userInfo: nil];
            }
            else
            {
                // By definition, it's a timeout.
                // I'm not returning a userInfo here: code is -1001
                *error = [NSError errorWithDomain: NSURLErrorDomain code: NSURLErrorTimedOut userInfo: nil];
            }
        }
        
        return ( NO );
    }
    
    // The asynchronous connection attempt has begun.
    return ( YES );
}

- (BOOL) connectToHost: (NSString *) hostname
                  port: (UInt16) port
                 error: (NSError **) error
{
    NSParameterAssert([hostname length] != 0);
    struct sockaddr_storage addrStore = {0};
    
    // Convert the hostname into a socket address. This method installs the
    // port number into any returned socket address, and generates an NSError
    // for us should something go wrong.
    if ( _SocketAddressFromString(hostname, NO, port, &addrStore, error) == NO )
        return ( NO );
    
    return ( [self connectToAddress: (struct sockaddr *)&addrStore
                              error: error] );
}

- (BOOL) connectToIPAddress: (NSString *) address
                       port: (UInt16) port
                      error: (NSError **) error
{
    NSParameterAssert([address length] != 0);
    struct sockaddr_storage addrStore = {0};
    
    // Convert the hostname into a socket address. This method installs the
    // port number into any returned socket address, and generates an NSError
    // for us should something go wrong.
    if ( _SocketAddressFromString(address, YES, port, &addrStore, error) == NO )
        return ( NO );
    
    return ( [self connectToAddress: (struct sockaddr *)&addrStore
                              error: error] );
}

- (void) writeBytes: (NSData *) bytes
         completion: (void (^)(NSData *, NSError *)) completionHandler
{
    NSParameterAssert([bytes length] != 0);
    
    if ( _socketIO == NULL )
    {
        [NSException raise: NSInternalInconsistencyException format: @"-[%@ %@]: socket is not connected.", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
    }
    
    // This copy call ensures we have an immutable data object. If we were 
    // passed an immutable NSData, the copy is actually only a retain.
    // We convert it to a CFDataRef in order to get manual reference counting
    // semantics in order to keep the data object alive until the dispatch_data_t
    // in which we're using it is itself released.
    CFDataRef staticData = CFBridgingRetain([bytes copy]);
    
    dispatch_data_t ddata = dispatch_data_create(CFDataGetBytePtr(staticData), CFDataGetLength(staticData), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // When the dispatch data object is deallocated, release our CFData ref.
        CFRelease(staticData);
    });
    dispatch_io_write(_socketIO, 0, ddata, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(_Bool done, dispatch_data_t data, int error) {
        if ( done == false )
            return;
        
        if ( completionHandler == NULL )
            return;     // no point going further, really
        
        if ( error == 0 )
        {
            // All the data was written successfully.
            completionHandler(nil, nil);
            return;
        }
        
        // Here we are once again relying upon CFErrorRef's magical 'fill in
        // the POSIX error userInfo' functionality.
        NSError * errObj = [NSError errorWithDomain: NSPOSIXErrorDomain code: error userInfo: nil];
        
        NSData * unwritten = nil;
        if ( data != NULL )
            unwritten = [[_AQDispatchData alloc] initWithDispatchData: data];
        
        completionHandler(unwritten, errObj);
#if USING_MRR
        [unwritten release];
#endif
    });
}

@end

@implementation AQSocket (CFSocketConnectionCallback)

- (void) connectedSuccessfully
{
    // Now that we're connected, we must set up a couple of things:
    //
    // 1. The dispatch IO channel through which we will handle reads and writes.
    // 2. The AQSocketReader object which will serve as our read buffer.
    // 3. The dispatch source which will notify us of incoming data.
    
    // Before all that though, we'll remove the CFSocketRef from the runloop.
    CFRunLoopRemoveSource(CFRunLoopGetMain(), _socketRunloopSource, kCFRunLoopDefaultMode);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), _socketRunloopSource, (__bridge CFStringRef)
#if TARGET_OS_IPHONE
                          UITrackingRunLoopMode
#else
                          NSEventTrackingRunLoopMode
#endif
                          );
    
    // All done with this one now.
    CFRelease(_socketRunloopSource);
    _socketRunloopSource = NULL;
    
    // First, the IO channel. We will have its cleanup handler release the
    // CFSocketRef for us; in other words, the IO channel now owns the
    // CFSocketRef.
    _socketIO = dispatch_io_create(DISPATCH_IO_STREAM, CFSocketGetNative(_socketRef), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int error) {
        if ( error != 0 )
            NSLog(@"Error in dispatch IO channel causing its shutdown: %d", error);
        
        // all done with the socket reference, make it noticeably go away.
        CFRelease(_socketRef);
        _socketRef = NULL;
    });
    
    // Next the socket reader object. This will keep track of all the data blobs
    // returned via dispatch_io_read(), providing peek support to the upper
    // protocol layers.
    _socketReader = [AQSocketReader new];
    
    // Now we create the source to tell us when data arrives.
    _readWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, CFSocketGetNative(_socketRef), 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    
    // The source handler will read all data asynchronously into a buffer
    // using dispatch_io_read(), and will suspend itself until the full read
    // is satisfied.
    dispatch_source_set_event_handler(_readWatcher, ^{
        // Pull down all available data into our AQSocketReader, then pass that
        // to the event handler once it's complete.
        dispatch_io_read(_socketIO, 0, SIZE_MAX, dispatch_get_current_queue(), ^(_Bool done, dispatch_data_t data, int error) {
            if ( data != NULL )
                [_socketReader appendDispatchData: data];
            
            if ( error != 0 )
                NSLog(@"dispatch_io_read() error: %d", error);
            
            if ( !done )
                return;
            
            // If we're using manual memory management, ensure the socket reader
            // doesn't go away during the client call.
#if USING_MRR
            [_socketReader retain];
#endif
            // We've read everything, so notify the event handler that there's
            // data waiting to be handled.
            self.eventHandler(AQSocketEventDataAvailable, _socketReader);
#if USING_MRR
            [_socketReader release];
#endif
            
            // Lastly, since we've run out of incoming data, we will resume the
            // read notification dispatch source.
            dispatch_resume(_readWatcher);
        });
        
        // Having enqueued our writes, let's suspend read notifications until
        // we've read all the incoming data.
        dispatch_suspend(_readWatcher);
    });
    
    // Dispatch sources are created in a suspended state, so we need to resume
    // this one for it to start working. However, we'll do it asynchronously on
    // the main thread, to ensure that it doesn't see the 'readable' state
    // reported by the connection success.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_resume(_readWatcher);
    });
}

- (void) connectionFailedWithError: (SInt32) err
{
    NSError * info = [NSError errorWithDomain: NSPOSIXErrorDomain code: err userInfo: nil];
    self.eventHandler(AQSocketEventConnectionFailed, info);
    
    // Get rid of the socket now, since we might try to re-connect, which will
    // create a new CFSocketRef.
    CFRelease(_socketRef); _socketRef = NULL;
}

@end
