/* -----------------------------------------------------------------------------
 * $Id: MBlock.c,v 1.26 2002/01/08 16:38:27 sof Exp $
 *
 * (c) The GHC Team 1998-1999
 *
 * MegaBlock Allocator Interface.  This file contains all the dirty
 * architecture-dependent hackery required to get a chunk of aligned
 * memory from the operating system.
 *
 * ---------------------------------------------------------------------------*/

/* This is non-posix compliant. */
/* #include "PosixSource.h" */

#include "Rts.h"
#include "RtsUtils.h"
#include "RtsFlags.h"
#include "MBlock.h"
#include "BlockAlloc.h"

#ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif

#ifdef HAVE_SYS_TYPES_H
#include <sys/types.h>
#endif

#ifndef mingw32_TARGET_OS
# ifdef HAVE_SYS_MMAN_H
# include <sys/mman.h>
# endif
#endif

#ifdef HAVE_FCNTL_H
#include <fcntl.h>
#endif

#if HAVE_WINDOWS_H
#include <windows.h>
#endif

lnat mblocks_allocated = 0;

void *
getMBlock(void)
{
  return getMBlocks(1);
}

#ifndef _WIN32
void *
getMBlocks(nat n)
{
  static caddr_t next_request = (caddr_t)HEAP_BASE;
  caddr_t ret;
  lnat size = MBLOCK_SIZE * n;
 
#ifdef solaris2_TARGET_OS
  { 
      int fd = open("/dev/zero",O_RDONLY);
      ret = mmap(next_request, size, PROT_READ | PROT_WRITE, 
		 MAP_FIXED | MAP_PRIVATE, fd, 0);
      close(fd);
  }
#elif hpux_TARGET_OS
 ret = mmap(next_request, size, PROT_READ | PROT_WRITE, 
	     MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
#elif darwin_TARGET_OS
 ret = mmap(next_request, size, PROT_READ | PROT_WRITE, 
            MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0);
#else
  ret = mmap(next_request, size, PROT_READ | PROT_WRITE, 
	     MAP_ANON | MAP_PRIVATE, -1, 0);
#endif
  
  if (ret == (void *)-1) {
    if (errno == ENOMEM) {
      barf("getMBlock: out of memory");
    } else {
      barf("GetMBlock: mmap failed");
    }
  }

  if (((W_)ret & MBLOCK_MASK) != 0) {
    barf("GetMBlock: misaligned block %p returned when allocating %d megablock(s) at %p", ret, n, next_request);
  }

  IF_DEBUG(gc,fprintf(stderr,"Allocated %d megablock(s) at %p\n",n,ret));

  next_request += size;

  mblocks_allocated += n;
  
  return ret;
}

#else /* _WIN32 */

/*
 On Win32 platforms we make use of the two-phased virtual memory API
 to allocate mega blocks. We proceed as follows:

 Reserve a large chunk of VM (256M at the time, or what the user asked
 for via the -M option), but don't supply a base address that's aligned on
 a MB boundary. Instead we round up to the nearest mblock from the chunk of
 VM we're handed back from the OS (at the moment we just leave the 'slop' at
 the beginning of the reserved chunk unused - ToDo: reuse it .)

 Reserving memory doesn't allocate physical storage (not even in the
 page file), this is done later on by committing pages (or mega-blocks in
 our case).
*/

char* base_non_committed = (char*)0;
char* end_non_committed = (char*)0;

/* Default is to reserve 256M of VM to minimise the slop cost. */
#define SIZE_RESERVED_POOL  ( 256 * 1024 * 1024 )

/* Number of bytes reserved */
static unsigned long size_reserved_pool = SIZE_RESERVED_POOL;

/* This predicate should be inlined, really. */
/* TODO: this only works for a single chunk */
int
is_heap_alloced(const void* x)
{
  return (((char*)(x) >= base_non_committed) && 
          ((char*)(x) <= end_non_committed));
}

void *
getMBlocks(nat n)
{
  static char* base_mblocks       = (char*)0;
  static char* next_request       = (char*)0;
  void* ret                       = (void*)0;

  lnat size = MBLOCK_SIZE * n;
  
  if ( (base_non_committed == 0) || (next_request + size > end_non_committed) ) {
    if (base_non_committed) {
      barf("RTS exhausted max heap size (%d bytes)\n", size_reserved_pool);
    }
    if (RtsFlags.GcFlags.maxHeapSize != 0) {
      size_reserved_pool = BLOCK_SIZE * RtsFlags.GcFlags.maxHeapSize;
      if (size_reserved_pool < MBLOCK_SIZE) {
	size_reserved_pool = 2*MBLOCK_SIZE;
      }
    }
    base_non_committed = VirtualAlloc ( NULL
                                      , size_reserved_pool
				      , MEM_RESERVE
				      , PAGE_READWRITE
				      );
    if ( base_non_committed == 0 ) {
         fprintf(stderr, "getMBlocks: VirtualAlloc failed with: %ld\n", GetLastError());
         ret=(void*)-1;
    } else {
      end_non_committed = (char*)base_non_committed + (unsigned long)size_reserved_pool;
      /* The returned pointer is not aligned on a mega-block boundary. Make it. */
      base_mblocks = (char*)((unsigned long)base_non_committed & (unsigned long)0xfff00000) + MBLOCK_SIZE;
#      if 0
       fprintf(stderr, "getMBlocks: Dropping %d bytes off of 256M chunk\n", 
	               (unsigned)base_mblocks - (unsigned)base_non_committed);
#      endif

       if ( ((char*)base_mblocks + size) > end_non_committed ) {
          fprintf(stderr, "getMBlocks: oops, committed too small a region to start with.");
	  ret=(void*)-1;
       } else {
          next_request = base_mblocks;
       }
    }
  }
  /* Commit the mega block(s) to phys mem */
  if ( ret != (void*)-1 ) {
     ret = VirtualAlloc(next_request, size, MEM_COMMIT, PAGE_READWRITE);
     if (ret == NULL) {
        fprintf(stderr, "getMBlocks: VirtualAlloc failed with: %ld\n", GetLastError());
        ret=(void*)-1;
     }
  }

  if (((W_)ret & MBLOCK_MASK) != 0) {
    barf("getMBlocks: misaligned block returned");
  }

  if (ret == (void*)-1) {
     barf("getMBlocks: unknown memory allocation failure on Win32.");
  }

  IF_DEBUG(gc,fprintf(stderr,"Allocated %d megablock(s) at 0x%x\n",n,(nat)ret));
  next_request = (char*)next_request + size;

  mblocks_allocated += n;
  
  return ret;
}

/* Hand back the physical memory that is allocated to a mega-block. 
   ToDo: chain the released mega block onto some list so that
         getMBlocks() can get at it.

   Currently unused.
*/
#if 0
void
freeMBlock(void* p, nat n)
{
  BOOL rc;

  rc = VirtualFree(p, n * MBLOCK_SIZE , MEM_DECOMMIT );
  
  if (rc == FALSE) {
#    ifdef DEBUG
     fprintf(stderr, "freeMBlocks: VirtualFree failed with: %d\n", GetLastError());
#    endif
  }

}
#endif

#endif
