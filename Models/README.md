# Speech model

Put the speech model here before you build. It is too large for Git (~530 MB).

1. Download `Parakeet.zip` from the [`model-v1` release](../../../releases/tag/model-v1).
2. Put it into this folder as it is, without unzipping: `Models/Parakeet.zip`.

When you build, the phase *Unpack Speech Model* of the target iDiktatKeyboard
(`Scripts/unpack-model.sh`) unpacks the ZIP straight into the keyboard extension in Xcode's build
folder (`iDiktatKeyboard.appex/Parakeet`). It runs again only when the ZIP changes. If the ZIP is
missing, the build stops with a hint.

The app never downloads anything: the model is part of the app.
