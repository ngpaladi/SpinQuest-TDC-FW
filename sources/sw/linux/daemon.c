/*
* Daemon to handle interrupts from the PL
* 
* Uses the following UIO devices:
*   - uio0: tdc_int                (PL -> PS interrupt)
*   - uio1: axi_bram_ctrl@a0000000 (BRAM 1)
*   - uio2: axi_bram_ctrl@a0002000 (BRAM 2)
*   - uio3: gpio@a0010000          (read_busy)
*   - which_bram: gpio@a0020000  (devices resolved by name at runtime)
*
* General description of functionality:
*   - create socket
*   - connect to socket
*   - wait for interrupt
*   - if interrupt:
*       - raise PS -> PL "read busy" flag 
*       - read PL -> PS signal describing which BRAM to read from 
*       - open UIOX file descriptor corresponding to that BRAM
*       - loop over BRAM, get data, send 
*       - close fds
*   - lower PS -> PL busy flag
*
*/
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <netinet/in.h>
#include <netdb.h> 
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>     // CHAR_BIT
#include "uio_find.h"

/* uio numbering is not stable (PS axi-pmon devices claim uio0-3 on the Krio
 * image), so devices are resolved by sysfs name/address at startup. */
static char UIO_INTR[32], UIO_BRAM1[32], UIO_BRAM2[32];
static char UIO_RDBUSY[32], UIO_BRAMSEL[32];

void error(const char *msg)
{
    perror(msg);
    exit(0);
}

int main(int argc, char *argv[])
{
    // Networking
    int sockfd, portno, n;
    struct sockaddr_in serv_addr;
    struct hostent *server;

    // File descriptors
    int uio_intr_fd;
    int uio_bram_fd;
    int uio_rdbusy_fd;
    int uio_bramsel_fd;

    // Pointers
    volatile uint64_t *uio_bram_ptr;
    volatile unsigned int *uio_rdbusy_ptr;
    volatile unsigned int *uio_bramsel_ptr;

    // Memory ranges (HARD-CODED FOR NOW - FIX ME)
    size_t uio_bram_len = 8192;
    size_t uio_rdbusy_len = 65536;
    size_t uio_bramsel_len = 65536;

    // Offsets (HARD-CODED FOR NOW - FIX ME)
    off_t offset = 0;

    // BRAM selection
    int which_bram;

    // Resolve UIO devices by name (see /sys/class/uio/*/name)
    if (uio_find("tdc_int",       0,            UIO_INTR,    sizeof UIO_INTR) ||
        uio_find("axi_bram_ctrl", 0xa0000000UL, UIO_BRAM1,   sizeof UIO_BRAM1) ||
        uio_find("axi_bram_ctrl", 0xa0002000UL, UIO_BRAM2,   sizeof UIO_BRAM2) ||
        uio_find("gpio",          0xa0010000UL, UIO_RDBUSY,  sizeof UIO_RDBUSY) ||
        uio_find("gpio",          0xa0020000UL, UIO_BRAMSEL, sizeof UIO_BRAMSEL)) {
        fprintf(stderr, "failed to resolve one or more UIO devices\n");
        exit(1);
    }
    printf("intr=%s bram1=%s bram2=%s read_busy=%s which_bram=%s\n",
           UIO_INTR, UIO_BRAM1, UIO_BRAM2, UIO_RDBUSY, UIO_BRAMSEL);

    // Create socket, connect
    if (argc < 3) {
       fprintf(stderr,"usage %s hostname port\n", argv[0]);
       exit(0);
    }
    portno = atoi(argv[2]);
    sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) 
        error("ERROR opening socket");
    else
        printf("Successfully opened socket\n");
    server = gethostbyname(argv[1]);
    if (server == NULL) {
        fprintf(stderr,"ERROR, no such host\n");
        exit(0);
    }
    bzero((char *) &serv_addr, sizeof(serv_addr));
    serv_addr.sin_family = AF_INET;
    bcopy((char *)server->h_addr, 
         (char *)&serv_addr.sin_addr.s_addr,
         server->h_length);
    serv_addr.sin_port = htons(portno);
    if (connect(sockfd,(struct sockaddr *) &serv_addr,sizeof(serv_addr)) < 0) 
        error("ERROR connecting");
    else 
        printf("Successfully connected to socket\n");

    // Open the TDC interrupt UIO device
    uio_intr_fd = open(UIO_INTR, O_RDWR);
    if (uio_intr_fd < 0) {
        /* note: /dev/uioX is root-only on the stock image — run with sudo */
        error("Failed to open the TDC interrupt UIO device");
    }
    else {
        printf("Opened the TDC interrupt UIO device...\n");
    }

    while (1) {

        printf("Daemon waiting for interrupts (triggers)...\n");

        // Unmask (clear) interrupt
        uint32_t info = 1; 
        ssize_t nb = write(uio_intr_fd, &info, sizeof(info));
        if (nb != (ssize_t)sizeof(info)) {
            error("Failed to write to (clear) TDC interrupt UIO device");
        }
        else {
            printf("Successfully unmasked tdc interrupt\n");
        }              

        // Wait for interrupt
        nb = read(uio_intr_fd, &info, sizeof(info));
        if (nb == (ssize_t)sizeof(info)) {
            printf("Trigger received. Interrupt #%u\n", info);
        }

        // 1. Raise PS -> PL "read busy" flag 
        uio_rdbusy_fd = open(UIO_RDBUSY, O_RDWR);
        if (uio_rdbusy_fd < 0) {
            error("Failed to open the read_busy UIO device");
        }
        else {
            printf("Opened the read_busy UIO device\n");
        }
        // Memory map the UIO device
        uio_rdbusy_ptr = mmap(NULL, uio_rdbusy_len, PROT_READ | PROT_WRITE, MAP_SHARED, uio_rdbusy_fd, offset);
        if (uio_rdbusy_ptr == MAP_FAILED) {
            error("Failed to mmap read_busy UIO device");
        }
        else {
            printf("successfully mmap'd read_busy UIO device\n");
        }
        // Write to the read_busy AXI GPIO data register
        uio_rdbusy_ptr[0] = 0x01;

        // 2. read PL -> PS signal describing which BRAM to read from 
        uio_bramsel_fd = open(UIO_BRAMSEL, O_RDWR);
        if (uio_bramsel_fd < 0) {
            error("Failed to open the which_bram UIO device");
        }
        else {
            printf("Opened the which_bram UIO device\n");
        }
        // Memory map the UIO device
        uio_bramsel_ptr = mmap(NULL, uio_bramsel_len, PROT_READ | PROT_WRITE, MAP_SHARED, uio_bramsel_fd, offset);
        if (uio_bramsel_ptr == MAP_FAILED) {
            error("Failed to mmap which_bram UIO device");
        }
        else {
            printf("successfully mmap'd which_bram UIO device\n");
        }
        // Read from the which_bram AXI GPIO data register
        which_bram = *(volatile uint32_t *)(uio_bramsel_ptr + offset);
        printf("which_bram: 0x%08x\n", which_bram);
        printf("Opening BRAM %d\n", which_bram);
        // Unmap the memory and close the UIO device
        munmap(uio_bramsel_ptr, uio_bramsel_len);
        close(uio_bramsel_fd);

        // 3. open UIOX file descriptor corresponding to that BRAM
        if (which_bram == 1) {
            uio_bram_fd = open(UIO_BRAM1, O_RDWR);
        }
        else {
            uio_bram_fd = open(UIO_BRAM2, O_RDWR);
        }
        if (uio_bram_fd < 0) {
            error("Failed to open the BRAM UIO device");
        }
        else {
            printf("Opened the BRAM UIO device\n");
        }
        // Map the BRAM memory into user space
        uio_bram_ptr = (volatile uint64_t *)mmap(NULL, uio_bram_len, PROT_READ | PROT_WRITE, MAP_SHARED, uio_bram_fd, offset);
        if (uio_bram_ptr == MAP_FAILED) {
            error("Failed to mmap BRAM");
        }

        // 4. Loop over the BRAM addresses: print and send over the socket
        for (int i=0; i<250; i+=1) {
            uint64_t bram_data = uio_bram_ptr[i];
            printf("%#018"PRIx64"\n", bram_data);
            n = write(sockfd, &bram_data, sizeof(bram_data));
            if (n < 0)
                error("ERROR writing to socket");
        }

        // Lower the read_busy flag
        uio_rdbusy_ptr[0] = 0x0;

        // Unmap the memory and close the read_busy UIO device
        munmap(uio_rdbusy_ptr, uio_rdbusy_len);
        close(uio_rdbusy_fd);

        // Close the BRAM file descriptor (bramsel already closed above)
        munmap((void *)uio_bram_ptr, uio_bram_len);
        close(uio_bram_fd);
    }
    
}
