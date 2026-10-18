# Audio Reverser

iPhone app that records from the microphone and plays the latest clip forward, backward, or at a speed from 0.1× to 3.0×.

## Open in Xcode

1. Open `AudioReverser.xcodeproj`.
2. Select the **Audio Reverser** scheme and an iPhone simulator running iOS 17 or later.
3. Run.

Xcode 15 or later. If Xcode asks for a signing team, choose your personal team. The simulator does not need a paid developer account. The simulator records from the Mac microphone.

## Microphone

The first time you tap Record, iOS asks for microphone access. The usage string (`NSMicrophoneUsageDescription`) is:

> Audio Reverser uses the microphone to record a clip you can play forward, backward, and at a different speed.

If you deny access, recording stays off until you allow the microphone in Settings. The app shows that state and a button that opens Settings.

## Playback

Forward playback reads the recording as captured. Reverse playback rewrites the PCM frames in time (each channel reversed); it does not use a negative playback rate. Speed is `AVAudioUnitTimePitch.rate`, from 0.1× to 3.0×, and the same rate applies to both directions. Pitch stays at the original.
