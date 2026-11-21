#import "BluetoothGateway.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#import <Network/Network.h>
#import <netinet/tcp.h>

static NSString *const ServiceUUID = @"9C9E1D7A-2A8B-4F2D-9C73-6A51E8C4B210";
static NSString *const PSMUUID = @"9C9E1D7A-2A8B-4F2D-9C73-6A51E8C4B211";
static NSDictionary *RFCOMMService(void) {
  uuid_t bytes;
  [[[NSUUID alloc] initWithUUIDString:@"71f55b60-e473-4c78-a90b-ec41d2f86c11"]
      getUUIDBytes:bytes];
  return @{
    @"0001 - ServiceClassIDList" :
        @[ [IOBluetoothSDPUUID uuidWithBytes:bytes length:sizeof(bytes)] ],
    @"0004 - ProtocolDescriptorList" : @[
      @[ [IOBluetoothSDPUUID uuid16:0x0100] ],
      @[
        [IOBluetoothSDPUUID uuid16:0x0003], @{
          @"DataElementType" : @1,
          @"DataElementSize" : @1,
          @"DataElementValue" : @12
        }
      ]
    ],
    @"0005 - BrowseGroupList" : @[ [IOBluetoothSDPUUID uuid16:0x1002] ],
    @"0100 - ServiceName" : @"PairIt"
  };
}

@interface PairItBluetoothGateway () <CBPeripheralManagerDelegate,
                                      IOBluetoothRFCOMMChannelDelegate,
                                      NSStreamDelegate>
@end
@implementation PairItBluetoothGateway {
  uint16_t _port;
  BOOL _running, _reading;
  NSString *_name;
  CBPeripheralManager *_peripheral;
  CBL2CAPPSM _psm;
  CBMutableCharacteristic *_psmCharacteristic;
  CBL2CAPChannel *_coc;
  IOBluetoothSDPServiceRecord *_record;
  IOBluetoothUserNotification *_notification;
  IOBluetoothRFCOMMChannel *_rfcomm;
  NSInputStream *_input;
  NSOutputStream *_output;
  NSMutableData *_outgoing;
  nw_connection_t _gateway;
  NSUInteger _queued;
  NSMutableDictionary<NSNumber *, NSData *> *_writes;
  NSData *_pendingRFCOMM;
  uintptr_t _tag;
  uint64_t _generation;
}
- (instancetype)initWithPort:(uint16_t)port {
  if ((self = [super init]))
    _port = port;
  return self;
}
- (void)startWithName:(NSString *)name {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_running)
      return;
    self->_running = YES;
    self->_name = [name copy];
    [self publishRFCOMM];
    self->_peripheral =
        [[CBPeripheralManager alloc] initWithDelegate:self
                                                queue:dispatch_get_main_queue()
                                              options:nil];
    [self status:@"Bluetooth starting…"];
  });
}
- (void)stop {
  void (^work)(void) = ^{
    self->_running = NO;
    [self->_notification unregister];
    self->_notification = nil;
    [self->_record removeServiceRecord];
    self->_record = nil;
    if (self->_psm)
      [self->_peripheral unpublishL2CAPChannel:self->_psm];
    [self->_peripheral stopAdvertising];
    [self->_peripheral removeAllServices];
    self->_peripheral = nil;
    self->_psm = 0;
    self->_psmCharacteristic = nil;
    [self close];
    [self status:@"Bluetooth is off"];
  };
  if (NSThread.isMainThread)
    work();
  else
    dispatch_async(dispatch_get_main_queue(), work);
}
- (void)publishRFCOMM {
  _record = [IOBluetoothSDPServiceRecord
      publishedServiceRecordWithDictionary:RFCOMMService()];
  BluetoothRFCOMMChannelID channel = 0;
  if (_record && [_record getRFCOMMChannelID:&channel] == kIOReturnSuccess &&
      channel)
    _notification = [IOBluetoothRFCOMMChannel
        registerForChannelOpenNotifications:self
                                   selector:@selector(opened:channel:)
                              withChannelID:channel
                                  direction:
                                      kIOBluetoothUserNotificationChannelDirectionIncoming];
  if (!_notification) {
    [_record removeServiceRecord];
    _record = nil;
  }
}
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)p {
  if (!_running || p != _peripheral)
    return;
  if (p.state == CBManagerStatePoweredOn)
    [p publishL2CAPChannelWithEncryption:YES];
  else
    [self status:@"Bluetooth unavailable · check System Settings"];
}
- (void)peripheralManager:(CBPeripheralManager *)p
    didPublishL2CAPChannel:(CBL2CAPPSM)psm
                     error:(NSError *)error {
  if (!_running || p != _peripheral || error) {
    [self status:@"Bluetooth unavailable · check permission"];
    return;
  }
  _psm = psm;
  CBMutableCharacteristic *c = [[CBMutableCharacteristic alloc]
      initWithType:[CBUUID UUIDWithString:PSMUUID]
        properties:CBCharacteristicPropertyRead
             value:nil
       permissions:CBAttributePermissionsReadEncryptionRequired];
  _psmCharacteristic = c;
  CBMutableService *s =
      [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString:ServiceUUID]
                                     primary:YES];
  s.characteristics = @[ c ];
  [p addService:s];
}
- (void)peripheralManager:(CBPeripheralManager *)p
            didAddService:(CBService *)s
                    error:(NSError *)error {
  if (!_running || p != _peripheral || error) {
    [self status:@"Couldn’t publish Bluetooth service"];
    return;
  }
  [p startAdvertising:@{
    CBAdvertisementDataServiceUUIDsKey :
        @[ [CBUUID UUIDWithString:ServiceUUID] ],
    CBAdvertisementDataLocalNameKey : _name ?: @"PairIt"
  }];
}
- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)p
                                       error:(NSError *)error {
  if (!_running || p != _peripheral)
    return;
  if (error) {
    [self status:@"Couldn’t advertise Bluetooth service"];
    return;
  }
  [self status:@"Bluetooth ready"];
}
- (void)peripheralManager:(CBPeripheralManager *)p
    didReceiveReadRequest:(CBATTRequest *)request {
  if (!_running || p != _peripheral ||
      request.characteristic != _psmCharacteristic) {
    [p respondToRequest:request withResult:CBATTErrorRequestNotSupported];
    return;
  }
  uint16_t value = CFSwapInt16HostToLittle(_psm);
  NSData *data = [NSData dataWithBytes:&value length:sizeof(value)];
  if (request.offset > data.length) {
    [p respondToRequest:request withResult:CBATTErrorInvalidOffset];
    return;
  }
  request.value =
      [data subdataWithRange:NSMakeRange(request.offset,
                                         data.length - request.offset)];
  [p respondToRequest:request withResult:CBATTErrorSuccess];
}
- (void)peripheralManager:(CBPeripheralManager *)p
      didOpenL2CAPChannel:(CBL2CAPChannel *)channel
                    error:(NSError *)error {
  if (!_running || p != _peripheral || error || _coc || _rfcomm) {
    [channel.inputStream close];
    [channel.outputStream close];
    return;
  }
  _coc = channel;
  _input = channel.inputStream;
  _output = channel.outputStream;
  _input.delegate = self;
  _output.delegate = self;
  [_input scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  [_output scheduleInRunLoop:NSRunLoop.mainRunLoop
                     forMode:NSRunLoopCommonModes];
  [_input open];
  [_output open];
  [self openGateway];
}
- (void)opened:(IOBluetoothUserNotification *)n
       channel:(IOBluetoothRFCOMMChannel *)channel {
  if (!_running || _coc || _rfcomm || !channel.getMTU) {
    [channel closeChannel];
    return;
  }
  _rfcomm = channel;
  _writes = [NSMutableDictionary new];
  if ([channel setDelegate:self] != kIOReturnSuccess) {
    [self close];
    return;
  }
  [self openGateway];
}
- (void)openGateway {
  uint64_t generation = ++_generation;
  nw_parameters_t params = nw_parameters_create_secure_tcp(
      NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t o) {
        nw_tcp_options_set_no_delay(o, true);
      });
  NSString *service = [NSString stringWithFormat:@"%u", _port];
  nw_connection_t connection = nw_connection_create(
      nw_endpoint_create_host("127.0.0.1", service.UTF8String), params);
  _gateway = connection;
  nw_connection_set_queue(connection, dispatch_get_main_queue());
  nw_connection_set_state_changed_handler(
      connection, ^(nw_connection_state_t state, nw_error_t error) {
        if (self->_gateway != connection || self->_generation != generation)
          return;
        if (state == nw_connection_state_ready) {
          [self status:@"Bluetooth phone connected"];
          [self readGateway];
        } else if (state == nw_connection_state_failed ||
                   state == nw_connection_state_waiting)
          [self close];
      });
  nw_connection_start(connection);
}
- (void)readGateway {
  if (!_gateway || _reading ||
      (_rfcomm && (_writes.count >= 8 || _pendingRFCOMM)) ||
      (_coc && _outgoing.length >= 32768))
    return;
  nw_connection_t connection = _gateway;
  uint64_t generation = _generation;
  _reading = YES;
  NSUInteger maximum = _rfcomm ? _rfcomm.getMTU : 16384;
  nw_connection_receive(
      _gateway, 1, maximum,
      ^(dispatch_data_t content, nw_content_context_t context, bool complete,
        nw_error_t error) {
        if (self->_gateway != connection || self->_generation != generation)
          return;
        self->_reading = NO;
        if (error || complete || !content) {
          [self close];
          return;
        }
        const void *bytes;
        size_t size;
        __attribute__((objc_precise_lifetime)) dispatch_data_t mapped =
            dispatch_data_create_map(content, &bytes, &size);
        NSData *data = [NSData dataWithBytes:bytes length:size];
        (void)mapped;
        if (self->_rfcomm)
          [self writeRFCOMM:data];
        else {
          if (!self->_outgoing)
            self->_outgoing = [NSMutableData new];
          [self->_outgoing appendData:data];
          [self flush];
          [self readGateway];
        }
      });
}
- (void)writeRFCOMM:(NSData *)data {
  NSNumber *key = @(++_tag);
  _writes[key] = data;
  IOReturn result = [_rfcomm writeAsync:(void *)data.bytes
                                 length:(UInt16)data.length
                                 refcon:(void *)_tag];
  if (result != kIOReturnSuccess) {
    [_writes removeObjectForKey:key];
    if ((result == kIOReturnNoResources || result == kIOReturnBusy) &&
        _writes.count) {
      _pendingRFCOMM = data;
    } else {
      [self close];
    }
  } else
    [self readGateway];
}
- (void)rfcommChannelWriteComplete:(IOBluetoothRFCOMMChannel *)channel
                            refcon:(void *)refcon
                            status:(IOReturn)result {
  if (channel != _rfcomm)
    return;
  [_writes removeObjectForKey:@((uintptr_t)refcon)];
  if (result != kIOReturnSuccess) {
    [self close];
    return;
  }
  if (_pendingRFCOMM) {
    NSData *pending = _pendingRFCOMM;
    _pendingRFCOMM = nil;
    [self writeRFCOMM:pending];
    return;
  }
  [self readGateway];
}
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel
                     data:(void *)bytes
                   length:(size_t)size {
  if (channel == _rfcomm && size)
    [self send:[NSData dataWithBytes:bytes length:size]];
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
  if (channel == _rfcomm)
    [self close];
}
- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
  if (stream != _input && stream != _output)
    return;
  if (event & (NSStreamEventErrorOccurred | NSStreamEventEndEncountered)) {
    [self close];
    return;
  }
  if (stream == _input && (event & NSStreamEventHasBytesAvailable)) {
    uint8_t bytes[16384];
    NSInteger n = [_input read:bytes maxLength:sizeof(bytes)];
    if (n > 0)
      [self send:[NSData dataWithBytes:bytes length:n]];
    else if (n < 0)
      [self close];
  }
  if (stream == _output && (event & NSStreamEventHasSpaceAvailable))
    [self flush];
}
- (void)flush {
  while (_output.hasSpaceAvailable && _outgoing.length) {
    NSInteger n = [_output write:_outgoing.bytes maxLength:_outgoing.length];
    if (n <= 0) {
      if (n < 0)
        [self close];
      return;
    }
    [_outgoing replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
  }
  [self readGateway];
}
- (void)send:(NSData *)data {
  if (!_gateway || _queued + data.length > 65536) {
    [self close];
    return;
  }
  _queued += data.length;
  nw_connection_t connection = _gateway;
  uint64_t generation = _generation;
  dispatch_data_t content = dispatch_data_create(
      data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  nw_connection_send(_gateway, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
                     true, ^(nw_error_t error) {
                       if (self->_gateway != connection ||
                           self->_generation != generation)
                         return;
                       self->_queued -= data.length;
                       if (error)
                         [self close];
                     });
}
- (void)close {
  _generation += 1;
  IOBluetoothRFCOMMChannel *r = _rfcomm;
  _rfcomm = nil;
  r.delegate = nil;
  [r closeChannel];
  [_input close];
  [_output close];
  _input.delegate = nil;
  _output.delegate = nil;
  _input = nil;
  _output = nil;
  _coc = nil;
  if (_gateway)
    nw_connection_cancel(_gateway);
  _gateway = nil;
  _writes = nil;
  _pendingRFCOMM = nil;
  _outgoing = nil;
  _reading = NO;
  _queued = 0;
  if (_running)
    [self status:@"Bluetooth ready"];
}
- (void)status:(NSString *)value {
  if (_statusChanged)
    _statusChanged(value);
}
@end
