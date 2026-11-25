# Speech model

Put the speech model here before you build. It is too large for Git (~600 MB).

1. Download `Parakeet.zip` from the [`model-v1` release](../../../releases/tag/model-v1).
2. Unzip it and move the resulting `Parakeet` folder into this folder.

The result must look like this:

```text
Models/Parakeet/Decoder.mlmodelc
Models/Parakeet/Encoder_v2.mlmodelc
Models/Parakeet/JointDecisionv3.mlmodelc
Models/Parakeet/Preprocessor.mlmodelc
Models/Parakeet/parakeet_vocab.json
Models/Parakeet/MODEL_CARD.md
```

Xcode copies the folder into the keyboard extension. The app never downloads anything.
