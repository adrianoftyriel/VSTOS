The installer ISO for this release is a workflow artifact rather than a release
asset, because a GitHub release asset is capped at 2 GB and the image is larger
than that. Build it yourself from the bundle in one command:

```sh
tar xzf vstos-*.tar.gz && cd vstos-*/
./build/build-iso.sh
```

`vstos-installer.iso.sha256` attached here is the checksum of the image CI built
from this commit, so a locally built image can be checked against it.
