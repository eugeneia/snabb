/* Use of this source code is governed by the Apache 2.0 license; see COPYING. */

enum { LINK_RING_SIZE    = 1024,
       LINK_MAX_PACKETS  = LINK_RING_SIZE - 1,
       CACHE_LINE        = 64
};

struct link {
  // this is a circular ring buffer, as described at:
  //   http://en.wikipedia.org/wiki/Circular_buffer
  char pad0[CACHE_LINE];
  // Two cursors:
  //   read:  the next element to be read
  //   write: the next element to be written
  int read, write;
  unsigned long dtime;
  char pad1[CACHE_LINE-2*sizeof(int)-sizeof(unsigned long)];
  // consumer-local cursors
  int lwrite, nread;
  unsigned long rxbytes, rxpackets;
  char pad2[CACHE_LINE-2*sizeof(int)-2*sizeof(unsigned long)];
  // producer-local cursors
  int lread, nwrite;
  unsigned long txbytes, txpackets, txdrop;
  char pad3[CACHE_LINE-2*sizeof(int)-3*sizeof(unsigned long)];
  struct packet *packets[LINK_RING_SIZE];
};

