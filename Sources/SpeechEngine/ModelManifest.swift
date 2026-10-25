// Generated from the model files Speech Key was tested with (FluidAudio 0.17.7, HuggingFace "main"
// on 2026-10-25, every file checked against HuggingFace's own fingerprints). Regenerate with
// scripts/model-manifest.py after updating FluidAudio or the models.

/// SHA-256 of every file in the speech-model folders Speech Key loads, by path under FluidAudio's
/// Models folder. `ModelIntegrity` refuses to use a folder whose files don't match.
enum ModelManifest {
    static let files: [String: String] = [
        "parakeet-ultra/Decoder.mlmodelc/analytics/coremldata.bin": "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5",
        "parakeet-ultra/Decoder.mlmodelc/coremldata.bin": "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497",
        "parakeet-ultra/Decoder.mlmodelc/model.mil": "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955",
        "parakeet-ultra/Decoder.mlmodelc/weights/weight.bin": "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4",
        "parakeet-ultra/Encoder.mlmodelc/analytics/coremldata.bin": "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d",
        "parakeet-ultra/Encoder.mlmodelc/coremldata.bin": "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe",
        "parakeet-ultra/Encoder.mlmodelc/model.mil": "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848",
        "parakeet-ultra/Encoder.mlmodelc/weights/weight.bin": "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b",
        "parakeet-ultra/JointDecisionv3.mlmodelc/analytics/coremldata.bin": "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4",
        "parakeet-ultra/JointDecisionv3.mlmodelc/coremldata.bin": "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4",
        "parakeet-ultra/JointDecisionv3.mlmodelc/model.mil": "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0",
        "parakeet-ultra/JointDecisionv3.mlmodelc/weights/weight.bin": "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25",
        "parakeet-ultra/Preprocessor.mlmodelc/analytics/coremldata.bin": "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d",
        "parakeet-ultra/Preprocessor.mlmodelc/coremldata.bin": "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d",
        "parakeet-ultra/Preprocessor.mlmodelc/metadata.json": "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf",
        "parakeet-ultra/Preprocessor.mlmodelc/model.mil": "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93",
        "parakeet-ultra/Preprocessor.mlmodelc/weights/weight.bin": "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea",
        "parakeet-ultra/config.json": "965c69bf500c7be18958df6438dc1ba897721690ae412937ca7c91e28cec1870",
        "parakeet-ultra/parakeet_v3_vocab.json": "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735",
        "parakeet-ultra/parakeet_vocab.json": "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735",
        "parakeet-ctc-110m-coreml/AudioEncoder.mlmodelc/analytics/coremldata.bin": "8906c823e9bb3bf6b16d9f0308f98cd70573526333ad85dd767dc3f9ae6b25fa",
        "parakeet-ctc-110m-coreml/AudioEncoder.mlmodelc/coremldata.bin": "a88b002b58193b4c31211754cdfdf220a85f9651dc61caf336ab84400cbc191a",
        "parakeet-ctc-110m-coreml/AudioEncoder.mlmodelc/metadata.json": "4f288bfe5cbe867ef1e592cdae33578b2fe59ada69182fc12209879558f985c2",
        "parakeet-ctc-110m-coreml/AudioEncoder.mlmodelc/model.mil": "2f84ef93a69115e55f3b5d8ce695b3c937de1833d4d229620634fae967cd587e",
        "parakeet-ctc-110m-coreml/AudioEncoder.mlmodelc/weights/weight.bin": "af0734b4a5d7465ad9e8bb170f0c53c5e6b91ebb75a9bdf88d3f59ae4ad6aebd",
        "parakeet-ctc-110m-coreml/MelSpectrogram.mlmodelc/analytics/coremldata.bin": "22f2a8cba1de25c984050566b534a1d8caf22a82f9fe6c1c6f3149a0dd7e8ae3",
        "parakeet-ctc-110m-coreml/MelSpectrogram.mlmodelc/coremldata.bin": "3a32ec67c76aa0aa2faef518413c311493e89aeb7fa11289fa4b8653ab8a160c",
        "parakeet-ctc-110m-coreml/MelSpectrogram.mlmodelc/metadata.json": "5e11d21a65c02bcfc37db43e941978e5d60d59e0efeadfda08e41f33b4f835d3",
        "parakeet-ctc-110m-coreml/MelSpectrogram.mlmodelc/model.mil": "0a7cb5693b39667295218bac5c7c09053f6bcd4b32699a83d06ac35d14ac6b79",
        "parakeet-ctc-110m-coreml/MelSpectrogram.mlmodelc/weights/weight.bin": "0a89c055bfde9022029d3cc59a23e949385e063974460d8eaec3a7614c3eaaa8",
        "parakeet-ctc-110m-coreml/config.json": "1fd77c83ea89285c242608d95a7992f146867481adc3938be730a064f3a63305",
        "parakeet-ctc-110m-coreml/ctc_head_metadata.json": "26100793bc6d3642d345cc52d7b8611d11510fa870d4d66ad93b204e0ba29d2e",
        "parakeet-ctc-110m-coreml/special_tokens_map.json": "af8c98917af6cb493513e5f1f8a35efdc28fa82cac15b2bb5f065d64f8bc904d",
        "parakeet-ctc-110m-coreml/tokenizer.json": "9f7c517c0bf644b1b690ab037bab4d4c53aecd38e047e7154d011013ab9160db",
        "parakeet-ctc-110m-coreml/tokenizer_config.json": "7a29ed0fec88768d8666d65be8dc00ae41a60c4b7758c4df99a912108e62a23a",
        "parakeet-ctc-110m-coreml/vocab.json": "319d386eead79aadc80df9c3ecc8340d1a727efb7c02a8847eb940380dd61e1f",
        "silero-vad/config.json": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
        "silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/analytics/coremldata.bin": "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909",
        "silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin": "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41",
        "silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/metadata.json": "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6",
        "silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil": "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270",
        "silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin": "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063",
    ]
}
