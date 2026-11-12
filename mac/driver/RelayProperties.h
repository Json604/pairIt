// Audio Relay's output-only device and configurable presentation latency.
// Included after Apple's driver implementation so common HAL behavior stays intact.
// 'arly' is a CFNumber in milliseconds; using a property list lets HAL marshal it
// across the driver process safely. The driver never opens sockets or captures audio.
static const AudioObjectPropertySelector kRelayLatency = 'arly';
static Float64 gRelayLatencyMs = 0;

static Boolean Relay_IsExtra(AudioObjectID object, const AudioObjectPropertyAddress* address) {
    return object == kObjectID_Device && address &&
        (address->mSelector == kRelayLatency || address->mSelector == kAudioObjectPropertyCustomPropertyInfoList);
}

static Boolean Relay_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                                const AudioObjectPropertyAddress* address) {
    if (driver != gAudioServerPlugInDriverRef || !address) return false;
    if (Relay_IsExtra(object, address)) return true;
    return NullAudio_HasProperty(driver, object, pid, address);
}

static OSStatus Relay_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
        const AudioObjectPropertyAddress* address, Boolean* settable) {
    if (driver != gAudioServerPlugInDriverRef || !address || !settable) return kAudioHardwareIllegalOperationError;
    if (Relay_IsExtra(object, address)) { *settable = address->mSelector == kRelayLatency; return noErr; }
    return NullAudio_IsPropertySettable(driver, object, pid, address, settable);
}

static OSStatus Relay_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
        const AudioObjectPropertyAddress* address, UInt32 qualifierSize, const void* qualifier, UInt32* size) {
    if (driver != gAudioServerPlugInDriverRef || !address || !size) return kAudioHardwareIllegalOperationError;
    if (object == kObjectID_Device) {
        switch (address->mSelector) {
            case kRelayLatency: *size = sizeof(CFNumberRef); return noErr;
            case kAudioObjectPropertyCustomPropertyInfoList: *size = sizeof(AudioServerPlugInCustomPropertyInfo); return noErr;
            case kAudioObjectPropertyControlList: *size = 0; return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams:
                *size = address->mScope == kAudioObjectPropertyScopeInput ? 0 : sizeof(AudioObjectID); return noErr;
        }
    }
    return NullAudio_GetPropertyDataSize(driver, object, pid, address, qualifierSize, qualifier, size);
}

static OSStatus Relay_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
        const AudioObjectPropertyAddress* address, UInt32 qualifierSize, const void* qualifier,
        UInt32 capacity, UInt32* size, void* data) {
    if (driver != gAudioServerPlugInDriverRef || !address || !size || (!data && capacity)) return kAudioHardwareIllegalOperationError;
    if (object != kObjectID_Device)
        return NullAudio_GetPropertyData(driver, object, pid, address, qualifierSize, qualifier, capacity, size, data);
    UInt32 needed = 0;
    OSStatus status = Relay_GetPropertyDataSize(driver, object, pid, address, qualifierSize, qualifier, &needed);
    if (status != noErr) return status;
    if (capacity < needed) return kAudioHardwareBadPropertySizeError;
    *size = needed;
    switch (address->mSelector) {
        case kRelayLatency: {
            pthread_mutex_lock(&gPlugIn_StateMutex);
            Float64 milliseconds = gRelayLatencyMs;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            *(CFNumberRef*)data = CFNumberCreate(NULL, kCFNumberFloat64Type, &milliseconds);
            return noErr;
        }
        case kAudioObjectPropertyCustomPropertyInfoList:
            *(AudioServerPlugInCustomPropertyInfo*)data = (AudioServerPlugInCustomPropertyInfo){
                kRelayLatency, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone };
            return noErr;
        case kAudioObjectPropertyControlList: return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (needed) *(AudioObjectID*)data = kObjectID_Stream_Output;
            return noErr;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            *(UInt32*)data = address->mScope == kAudioObjectPropertyScopeOutput; return noErr;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *(UInt32*)data = 0; return noErr;
        case kAudioDevicePropertyLatency:
            pthread_mutex_lock(&gPlugIn_StateMutex);
            *(UInt32*)data = address->mScope == kAudioObjectPropertyScopeInput ? 0 : (UInt32)llround(gRelayLatencyMs * gDevice_SampleRate / 1000.0);
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            return noErr;
    }
    return NullAudio_GetPropertyData(driver, object, pid, address, qualifierSize, qualifier, capacity, size, data);
}

static OSStatus Relay_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
        const AudioObjectPropertyAddress* address, UInt32 qualifierSize, const void* qualifier, UInt32 size, const void* data) {
    if (driver != gAudioServerPlugInDriverRef || !address) return kAudioHardwareIllegalOperationError;
    if (object != kObjectID_Device || address->mSelector != kRelayLatency)
        return NullAudio_SetPropertyData(driver, object, pid, address, qualifierSize, qualifier, size, data);
    if (!data || size != sizeof(CFNumberRef)) return kAudioHardwareBadPropertySizeError;
    CFNumberRef number = *(CFNumberRef*)data;
    Float64 milliseconds = 0;
    if (!number || CFGetTypeID(number) != CFNumberGetTypeID() ||
        !CFNumberGetValue(number, kCFNumberFloat64Type, &milliseconds) ||
        !isfinite(milliseconds) || milliseconds < 0 || milliseconds > 2000) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    Boolean changed = gRelayLatencyMs != milliseconds;
    gRelayLatencyMs = milliseconds;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if (changed) {
        AudioObjectPropertyAddress changes[] = {
            {kRelayLatency, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain}
        };
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 2, changes);
    }
    return noErr;
}
