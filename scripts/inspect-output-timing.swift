// Live AUHAL diagnostic: renders silence for two seconds; records no audio.
import Foundation
import CoreAudio
import AudioToolbox

var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var device: AudioObjectID = 0, size: UInt32 = 4
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
address.mSelector = kAudioDevicePropertyNominalSampleRate
var sampleRate = 48000.0; size = 8
AudioObjectGetPropertyData(device, &address, 0, nil, &size, &sampleRate)
print("selectedOutput", device, "sampleRate", sampleRate)
var hardwareLatencyMs = 0.0
var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
let component = AudioComponentFindNext(nil, &description)!
var unit: AudioUnit?
print("create", AudioComponentInstanceNew(component, &unit))
let output = unit!
print("device", device, AudioUnitSetProperty(output, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, 4))
var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
print("format", AudioUnitSetProperty(output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
var leads = [Double](repeating: 0, count: 512)
var count = 0
var callback = AURenderCallbackStruct(inputProc: { _, _, time, _, _, ioData in
    if let ioData { for buffer in UnsafeMutableAudioBufferListPointer(ioData) { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } } }
    if count < leads.count {
        let target = AudioConvertHostTimeToNanos(time.pointee.mHostTime)
        let now = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        leads[count] = Double(Int64(target) - Int64(now)) / 1e6; count += 1
    }
    return noErr
}, inputProcRefCon: nil)
print("callback", AudioUnitSetProperty(output, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
print("init", AudioUnitInitialize(output))
var latency = 0.0; size = 8
print("latency", AudioUnitGetProperty(output, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size), latency * 1000)
hardwareLatencyMs = latency * 1000
for (name, selector) in [("deviceLatency", kAudioDevicePropertyLatency), ("safetyOffset", kAudioDevicePropertySafetyOffset), ("bufferFrames", kAudioDevicePropertyBufferFrameSize)] {
    address.mSelector = selector; address.mScope = kAudioObjectPropertyScopeOutput
    var frames: UInt32 = 0; size = 4
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames)
    let ms = Double(frames) / sampleRate * 1000
    print(name, "status", status, "frames", frames, "ms", ms)
    if selector == kAudioDevicePropertyLatency { hardwareLatencyMs += ms }
}
address.mSelector = kAudioDevicePropertyStreams; address.mScope = kAudioObjectPropertyScopeOutput
AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
var streams = [AudioStreamID](repeating: 0, count: Int(size)/4)
AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams)
for stream in streams.prefix(1) {
    address.mSelector = kAudioStreamPropertyLatency; address.mScope = kAudioObjectPropertyScopeGlobal
    var frames: UInt32 = 0; size = 4
    let status = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &frames)
    let ms = Double(frames) / sampleRate * 1000
    print("firstStreamLatency", "status", status, "frames", frames, "ms", ms)
    hardwareLatencyMs += ms
}
print("start", AudioOutputUnitStart(output))
Thread.sleep(forTimeInterval: 2)
AudioOutputUnitStop(output)
AudioUnitUninitialize(output); AudioComponentInstanceDispose(output)
let values = leads.prefix(count).sorted()
print("OUTPUT_CALLBACK", "count", count, "minMs", values.first ?? 0, "medianMs", values.isEmpty ? 0 : values[values.count/2], "maxMs", values.last ?? 0)

let callbackLead = values.isEmpty ? 0 : values[values.count/2]
print("CLIENT_PRESENTATION_ESTIMATE_MS", max(0, callbackLead) + hardwareLatencyMs)
