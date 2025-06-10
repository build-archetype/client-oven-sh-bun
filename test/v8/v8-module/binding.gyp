{
  "targets": [
    {
      "target_name": "v8tests",
      "sources": ["main.cpp"],
      "cflags_cc": ["-std=c++20"],
      "msvs_settings": {
        "VCCLCompilerTool": {
          "AdditionalOptions": ["/std:c++20"]
        }
      },
      "xcode_settings": {
        "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
        "MACOSX_DEPLOYMENT_TARGET": "10.15"
      }
    }
  ]
}
