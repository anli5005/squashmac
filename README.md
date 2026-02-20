# squashmac

## Setup

Before opening the project in Xcode, you'll need to:
1. Check out the `squashfuse` submodule
2. Configure and build squashfuse by running these commands inside `squashfuse`:

```bash
./autogen.sh
./configure --disable-fuse --with-zlib=/usr --without-xz
make
```

You may need to install a few build dependencies:

```bash
brew install autoconf automake pkg-config libtool
```

## Usage

Once the app is running:

1. Go to **System Settings**. Under **General > Login Items & Extensions**, scroll down to the list of extensions. Select **By Category**, **File System Extensions**, then enable **squashmacfs**.
2. Double-click a squashfs archive to mount it, or use `mount -t squashfs` in the terminal.
