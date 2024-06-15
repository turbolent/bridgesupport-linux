# About

BridgeSupport is a Ruby C Extension that is used to generate
["Framework metadata"](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/RubyPythonCocoa/Articles/GenerateFrameworkMetadata.html)
for C and Objective C header files.

This is a hard fork of RubyMotion/Apple's version which runs (only) on Linux (for now).

# How to Build
- Assumses you are on Linux
- Run:

  ```
  make clean
  make
  ```

  NOTE: compilation will take a while (30 min+).

- Once compiled and installed, run the following command to perform a precursory test:

  ```
  cd test
  sh ./sample.sh
  cat ./sample.bridgesupport
  ```

  If the command above runs without errors, your environment is set up correctly.

- You can run the test suite using the following command:

  ```
  cd test
  rake test
  ```

- All the source code for BridgeSupport is located under the `./swig`
  directory. You can change the source code there and then run the
  following to build, install, and test your changes:

  ```
  make rebuild
  cd test
  rake test
  ```
