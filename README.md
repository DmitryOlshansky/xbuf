# xbuf

A buffer that loads data from external source automatically managing its size.

The key parameters are:
* `capacity` - initial capacity
* `minLoading` - minimum number of bytes to load in one call to the data source
* `loader` - a delegate that should load data into buffer, returning number of loaded byts, 0 on end of input and negative to indicate error
* `growBy` - granularity of allocation, uses OS page size by default

The application can manipulate contents of the buffer by calling `load`, `resize` and `compact`.  Load loads more data into the buffer, extending the buffer to load at least `minLoading` bytes. `load` is potentially blocking if loader is doing synchronious I/O.
`resize` allows application to manually resize the buffer for instance to shrink the buffer or to more agressively extend the buffer - for instance if the protocol contains payload size. `compact` discards a number of bytes up to `size`, it should be called by application after it processed a number of bytes and no longer needs. `compact` invalidates all slices into buffer be careful not to `compact` while holding references to the buffer.

```d
///
unittest {
    // capacity 32, min loading size 16, grow granularity 10
    XBuf buf = XBuf(32, 16, (slice) { 
        foreach (i, ref s; slice) {
            s = cast(ubyte)i;
        }
        return cast(int)slice.length;
    }, 10);
    buf.load();
    // loaded full buffer of 0..32
    foreach (i; 0..32) {
        assert(buf[i] == i);
    }
    buf.load();
    // capacity is 32+16 rounded to 10
    assert(buf.size == 50);
    foreach (i; 0..32){
        assert(buf[i] == i);
    }
    foreach (i; 32..50) {
        assert(buf[i] == i - 32);
    }
    buf.compact(20);
    // all of the first 20 bytes were overwritten
    foreach (i; 20..32) {
        assert(buf[i-20] == i);
    }
}

```