# immich-alpine
Run immich server on Alpine Linux. No building required.

This follows the immich versions for every x.y.z release. Support started from v3.2.0. Anything before that is not
supported. Though, you are welcome to try them out, but it won't be as simple as running the install script.

> [!NOTE]
> This is a work in progress at the moment. I'm validating the build and install scripts.

## Installation

```bash
# Download the install script
wget -O install-immich-alpine.sh \
  https://raw.githubusercontent.com/ronhombre/immich-alpine/main/install-immich-alpine.sh
chmod +x install-immich-alpine.sh

# Install a specific release
./install-immich-alpine.sh v3.2.0 ronhombre/immich-alpine
```

## References
- Heavily inspired by [arter97/immich-native](https://github.com/arter97/immich-native). I made this because I wanted to
run Immich on Alpine Linux and reduce the memory footprint. I also hated having to build the server myself every time.

## License
```text
MIT License

Copyright (c) 2026 Ron Lauren Hombre

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```