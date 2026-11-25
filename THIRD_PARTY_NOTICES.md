# Third-party components

## Template: ios-keyboard-dictation

Microphone capture through a hidden WebView (`iDiktatKeyboard/WebAudioCapture.swift`) and the
basic structure of the keyboard come from
[stephancill/ios-keyboard-dictation](https://github.com/stephancill/ios-keyboard-dictation),
Copyright (c) 2026 Stephan Cilliers, MIT License (see `LICENSE`).

## Speech model: Parakeet TDT 0.6B v3

`Models/Parakeet.zip` (downloaded separately, see `Models/README.md`) contains the Core ML version of
[nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3),
converted by FluidInference
([FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)).

License: [Creative Commons Attribution 4.0 (CC-BY-4.0)](https://creativecommons.org/licenses/by/4.0/).
The model has not been modified. The `Parakeet.zip` release asset contains an unchanged subset of
the files from the FluidInference repository. Keep this attribution when you distribute the app or
the model.

## Decoding algorithm: FluidAudio

`Shared/ParakeetTranscriber.swift` is an independent, heavily reduced implementation. The model
inputs and outputs and the greedy TDT decoding loop follow
[FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio),
Apache License 2.0. No code package from FluidAudio is included.
