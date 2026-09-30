# Building `llama.cpp` on Fedora with CUDA

This guide shows how to compile `llama.cpp` on Fedora and how to troubleshoot common CUDA errors such as:

- `CUDA Toolkit not found`
- `Could not find nvcc`
- `No CMAKE_CUDA_COMPILER could be found`
- `The CUDA compiler identification is unknown`

## 1. Install build tools

```bash
sudo dnf install git cmake gcc gcc-c++ make ninja-build openssl-devel
```

## 2. Clone `llama.cpp`

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
```

## 3. Test a CPU build first

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```

Check the binaries:

```bash
ls build/bin
./build/bin/llama-cli --version
```

## 4. Check NVIDIA and CUDA

Check whether the NVIDIA driver works:

```bash
nvidia-smi
```

Check whether the CUDA compiler is available:

```bash
nvcc --version
which nvcc
```

If `nvidia-smi` works but `nvcc` is missing, the NVIDIA driver is installed but the CUDA Toolkit is either missing or not in your `PATH`.

## 5. Find `nvcc`

```bash
find /usr/local /usr -name nvcc -type f 2>/dev/null
```

Typical locations are:

```text
/usr/local/cuda/bin/nvcc
/usr/local/cuda-13.x/bin/nvcc
```

Verify it directly:

```bash
/usr/local/cuda/bin/nvcc --version
```

Use the actual path returned by `find` if yours is different.

## 6. Add CUDA to your environment

For the current shell:

```bash
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
export CUDACXX=/usr/local/cuda/bin/nvcc
```

Verify:

```bash
echo $CUDACXX
which nvcc
nvcc --version
```

To make the path persistent:

```bash
echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
echo 'export CUDACXX=/usr/local/cuda/bin/nvcc' >> ~/.bashrc
source ~/.bashrc
```

## 7. Build `llama.cpp` with CUDA

Always remove the previous CMake build directory after changing CUDA settings:

```bash
rm -rf build
```

Then configure:

```bash
cmake -B build   -DGGML_CUDA=ON   -DCMAKE_BUILD_TYPE=Release
```

Compile:

```bash
cmake --build build -j$(nproc)
```

## 8. If CMake still cannot find the CUDA compiler

Specify `nvcc` explicitly:

```bash
rm -rf build

cmake -B build   -DGGML_CUDA=ON   -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc   -DCUDAToolkit_ROOT=/usr/local/cuda   -DCMAKE_BUILD_TYPE=Release

cmake --build build -j$(nproc)
```

If CUDA is installed in a versioned directory, for example:

```text
/usr/local/cuda-13.0/bin/nvcc
```

use:

```bash
cmake -B build   -DGGML_CUDA=ON   -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc   -DCUDAToolkit_ROOT=/usr/local/cuda-13.0   -DCMAKE_BUILD_TYPE=Release
```

## 9. Error: `CUDA Toolkit not found`

Example:

```text
Could not find `nvcc` executable in any searched paths.
Please set CUDAToolkit_ROOT.

CUDA Toolkit not found
```

First locate CUDA:

```bash
find /usr/local -name nvcc -type f 2>/dev/null
```

Then pass the CUDA directory to CMake:

```bash
cmake -B build   -DGGML_CUDA=ON   -DCUDAToolkit_ROOT=/usr/local/cuda   -DCMAKE_BUILD_TYPE=Release
```

## 10. Error: `No CMAKE_CUDA_COMPILER could be found`

Example:

```text
The CUDA compiler identification is unknown

No CMAKE_CUDA_COMPILER could be found.
```

Set either `CUDACXX`:

```bash
export CUDACXX=/usr/local/cuda/bin/nvcc
```

or pass the compiler directly:

```bash
cmake -B build   -DGGML_CUDA=ON   -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc   -DCMAKE_BUILD_TYPE=Release
```

Before retrying, remove the existing build cache:

```bash
rm -rf build
```

## 11. If `nvcc --version` works but CMake still fails

This often means `nvcc` itself is found but its test compilation is failing.

Check:

```bash
gcc --version
cmake --version
nvcc --version
```

On Fedora, a possible cause is that the installed GCC version is newer than the CUDA Toolkit supports.

Look for CMake error details:

```bash
find build/CMakeFiles -iname '*error*' -o -iname '*output*'
```

If present, also inspect:

```bash
cat build/CMakeFiles/CMakeError.log
```

An error such as:

```text
unsupported GNU version
```

usually points to a CUDA/GCC compatibility problem.

## 12. Diagnostic commands

Run this block when troubleshooting:

```bash
echo "=== Fedora ==="
cat /etc/fedora-release

echo "=== NVCC location ==="
which nvcc
find /usr/local -name nvcc -type f 2>/dev/null

echo "=== NVCC ==="
nvcc --version

echo "=== GCC ==="
gcc --version | head -1

echo "=== CMake ==="
cmake --version | head -1

echo "=== NVIDIA ==="
nvidia-smi --query-gpu=name,driver_version --format=csv
```

## 13. Run a model with GPU offloading

After a successful CUDA build:

```bash
./build/bin/llama-cli   -m /path/to/model.gguf   -ngl 999
```

`-ngl` controls how many model layers are offloaded to the GPU. A high value such as `999` tells `llama.cpp` to offload as many layers as possible.

You can also start the HTTP server:

```bash
./build/bin/llama-server   -m /path/to/model.gguf   -ngl 999
```

## Recommended troubleshooting order

1. Confirm `nvidia-smi` works.
2. Confirm `nvcc --version` works.
3. Find the exact `nvcc` path.
4. Delete the old `build` directory.
5. Set `CUDACXX` or `CMAKE_CUDA_COMPILER`.
6. Set `CUDAToolkit_ROOT` if necessary.
7. Check GCC/CUDA compatibility if CMake still reports an unknown CUDA compiler.
