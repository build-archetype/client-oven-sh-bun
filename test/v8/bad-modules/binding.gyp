{
  "targets": [
    {
      "target_name": "mismatched_abi_version",
      "sources": ["mismatched_abi_version.cpp"],
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
    },
    {
      "target_name": "no_entrypoint",
      "sources": ["no_entrypoint.cpp"],
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
