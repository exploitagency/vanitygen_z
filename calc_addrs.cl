/*
 * Vanitygen, vanity bitcoin address generator
 * Copyright (C) 2011 <samr7@cs.washington.edu>
 *
 * Vanitygen is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version. 
 *
 * Vanitygen is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with Vanitygen.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * This file contains an OpenCL kernel for performing certain parts of
 * the bitcoin address calculation process.
 *
 * Kernel: calc_addrs
 *
 * Inputs:
 * - Row of (sequential) EC points
 * - Array of column increment EC points (= rowsize * Pgenerator)
 *
 * Steps:
 * - For each row increment value C:
 *   - For each row point P:
 *      - Compute P + C
 *      - Normalize and hash with SHA256 and RIPEMD160
 *      - Store hash value in output array
 *
 * Output:
 * - Array of 20-byte address hash values
 *
 * Each instance of the kernel computes one full row.  With a typical
 * row size of 256 points, this makes each kernel instance very heavy.
 * This tradeoff is chosen in favor of batched modular inversion, which
 * substantially reduces the cost of performing modular inversion.
 */


/* Byte-swapping and endianness */
#define bswap32(v)					\
	(((v) >> 24) | (((v) >> 8) & 0xff00) |		\
	 (((v) << 8) & 0xff0000) | ((v) << 24))

#if __ENDIAN_LITTLE__ != 1
#define load_le32(v) bswap32(v)
#define load_be32(v) (v)
#else
#define load_le32(v) (v)
#define load_be32(v) bswap32(v)
#endif


/*
 * BIGNUM mini-library
 * This module deals with fixed-size 256-bit bignums.
 * Where modular arithmetic is performed, the SECP256k1 prime
 * modulus (below) is assumed.
 *
 * Methods include:
 * - bn_is_zero/bn_is_one/bn_is_odd/bn_is_even/bn_is_bit_set
 * - bn_rshift[1]/bn_lshift[1]
 * - bn_neg
 * - bn_uadd/bn_uadd_p
 * - bn_usub/bn_usub_p
 */

typedef uint bn_word;
#define BN_NBITS 256
#define BN_WSHIFT 5
#define BN_WBITS (1 << BN_WSHIFT)
#define BN_NWORDS ((BN_NBITS/8) / sizeof(bn_word))
#define BN_WORDMAX 0xffffffff

#define MODULUS_BYTES \
	0xfffffc2f, 0xfffffffe, 0xffffffff, 0xffffffff, \
	0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff

typedef struct {
	bn_word d[BN_NWORDS];
} bignum;

__constant bn_word modulus[] = { MODULUS_BYTES };
__constant bn_word bn_one[BN_NWORDS] = { 1, 0, };
__constant bignum bn_zero;

__constant bn_word mont_rr[BN_NWORDS] = { 0xe90a1, 0x7a2, 0x1, 0, };
__constant bn_word mont_n0[2] = { 0xd2253531, 0xd838091d };


#define bn_is_odd(bn)		(bn.d[0] & 1)
#define bn_is_even(bn) 		(!bn_is_odd(bn))
#define bn_is_zero(bn) 		(!bn.d[0] && !bn.d[1] && !bn.d[2] && \
				 !bn.d[3] && !bn.d[4] && !bn.d[5] && \
				 !bn.d[6] && !bn.d[7])
#define bn_is_one(bn) 		((bn.d[0] == 1) && !bn.d[1] && !bn.d[2] && \
				 !bn.d[3] && !bn.d[4] && !bn.d[5] && \
				 !bn.d[6] && !bn.d[7])
#define bn_is_bit_set(bn, n) \
	((((bn_word*)&bn)[n >> BN_WSHIFT]) & (1 << (n & (BN_WBITS-1))))


/*
 * Bitwise shift
 */

void
bn_lshift1(bignum *bn)
{
	int i;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = (BN_NWORDS - 1); i > 0; i--)
		bn->d[i] = (bn->d[i] << 1) | (bn->d[i-1] >> 31);
	bn->d[i] <<= 1;
}

void
bn_rshift(bignum *bn, int shift)
{
	int i, wd, iws, iwr;
	bn_word ihw, ilw;
	iws = (shift & (BN_WBITS-1));
	iwr = BN_WBITS - iws;
	wd = (shift >> BN_WSHIFT);
	ihw = (wd < BN_WBITS) ? bn->d[wd] : 0;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0, wd++; i < (BN_NWORDS-1); i++, wd++) {
		ilw = ihw;
		ihw = (wd < BN_WBITS) ? bn->d[wd] : 0;
		bn->d[i] = (ilw >> iws) | (ihw << iwr);
	}
	bn->d[i] = (ihw >> iws);
}

void
bn_rshift1(bignum *bn)
{
	int i;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < (BN_NWORDS - 1); i++)
		bn->d[i] = (bn->d[i+1] << 31) | (bn->d[i] >> 1);
	bn->d[i] >>= 1;
}


/*
 * Unsigned comparison
 */

int
bn_ucmp(bignum *a, bignum *b)
{
	int i;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = (BN_NWORDS - 1); i >= 0; i--) {
		if (a->d[i] < b->d[i]) return -1;
		if (a->d[i] > b->d[i]) return 1;
	}
	return 0;
}

int
bn_ucmp_c(bignum *a, __constant bn_word *b)
{
	int i;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = (BN_NWORDS - 1); i >= 0; i--) {
		if (a->d[i] < b[i]) return -1;
		if (a->d[i] > b[i]) return 1;
	}
	return 0;
}

/*
 * Negate
 */

void
bn_neg(bignum *n)
{
	int i, c;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0, c = 1; i < BN_NWORDS; i++)
		c = (n->d[i] = (~n->d[i]) + c) ? 0 : c;
}

/*
 * Add/subtract
 */

#define bn_add_word(r, a, b, t, c) do {		\
		t = a + b;			\
		c = (t < a) ? 1 : 0;		\
		r = t;				\
	} while (0)

#define bn_addc_word(r, a, b, t, c) do {			\
		t = a + b + c;					\
		c = (t < a) ? 1 : ((c & (t == a)) ? 1 : 0);	\
		r = t;						\
	} while (0)

bn_word
bn_uadd(bignum *r, bignum *a, bignum *b)
{
	bn_word t, c = 0;
	int i;
	bn_add_word(r->d[0], a->d[0], b->d[0], t, c);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 1; i < BN_NWORDS; i++)
		bn_addc_word(r->d[i], a->d[i], b->d[i], t, c);
	return c;
}

bn_word
bn_uadd_c(bignum *r, bignum *a, __constant bn_word *b)
{
	bn_word t, c = 0;
	int i;
	bn_add_word(r->d[0], a->d[0], b[0], t, c);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 1; i < BN_NWORDS; i++)
		bn_addc_word(r->d[i], a->d[i], b[i], t, c);
	return c;
}

#define bn_sub_word(r, a, b, t, c) do {		\
		t = a - b;			\
		c = (a < b) ? 1 : 0;		\
		r = t;				\
	} while (0)

#define bn_subb_word(r, a, b, t, c) do {	\
		t = a - (b + c);		\
		c = (!(a) && c) ? 1 : 0;	\
		c |= (a < b) ? 1 : 0;		\
		r = t;				\
	} while (0)

bn_word
bn_usub(bignum *r, bignum *a, bignum *b)
{
	bn_word t, c = 0;
	int i;
	bn_sub_word(r->d[0], a->d[0], b->d[0], t, c);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 1; i < BN_NWORDS; i++)
		bn_subb_word(r->d[i], a->d[i], b->d[i], t, c);
	return c;
}

bn_word
bn_usub_c(bignum *r, bignum *a, __constant bn_word *b)
{
	bn_word t, c = 0;
	int i;
	bn_sub_word(r->d[0], a->d[0], b[0], t, c);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 1; i < BN_NWORDS; i++)
		bn_subb_word(r->d[i], a->d[i], b[i], t, c);
	return c;
}

/*
 * Modular add/sub
 */

void
bn_mod_add(bignum *r, bignum *a, bignum *b)
{
	if (bn_uadd(r, a, b) ||
	    (bn_ucmp_c(r, modulus) >= 0))
		bn_usub_c(r, r, modulus);
}

void
bn_mod_sub(bignum *r, bignum *a, bignum *b)
{
	if (bn_usub(r, a, b))
		bn_uadd_c(r, r, modulus);
}

void
bn_mod_lshift1(bignum *bn)
{
	bn_word c = (bn->d[BN_NWORDS-1] & 0x80000000);
	bn_lshift1(bn);
	if (c || (bn_ucmp_c(bn, modulus) >= 0))
		bn_usub_c(bn, bn, modulus);
}

/*
 * Montgomery multiplication
 *
 * This includes normal multiplication of two "Montgomeryized"
 * bignums, and bn_from_mont for de-Montgomeryizing a bignum.
 */

#define bn_mul_word(r, a, w, c, p, s) do { \
		p = mul_hi(a, w);	   \
		r = (a * w) + c;	   \
		c = (r < c) ? p + 1 : p;   \
	} while (0)

#define bn_mul_add_word(r, a, w, c, p, s) do {	\
		p = mul_hi(a, w);		\
		s = r + c;			\
		r = (a * w) + s;		\
		c = (s < c) ? p + 1 : p;	\
		if (r < s) c++;			\
	} while (0)

void
bn_mul_mont(bignum *r, bignum *a, bignum *b)
{
	bignum t;
	bn_word tea, teb, c, p, s, m;
	int i, j;

	c = 0;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (j = 0; j < BN_NWORDS; j++)
		bn_mul_word(t.d[j], a->d[j], b->d[0], c, p, s);
	tea = c;
	teb = 0;

	c = 0;
	m = t.d[0] * mont_n0[0];
	bn_mul_add_word(t.d[0], modulus[0], m, c, p, s);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (j = 1; j < BN_NWORDS; j++) {
		bn_mul_add_word(t.d[j], modulus[j], m, c, p, s);
		t.d[j-1] = t.d[j];
	}
	t.d[BN_NWORDS-1] = tea + c;
	tea = teb + ((t.d[BN_NWORDS-1] < c) ? 1 : 0);

	for (i = 1; i < BN_NWORDS; i++) {
		c = 0;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
		for (j = 0; j < BN_NWORDS; j++)
			bn_mul_add_word(t.d[j], a->d[j], b->d[i], c, p, s);
		tea += c;
		teb = ((tea < c) ? 1 : 0);

		c = 0;
		m = t.d[0] * mont_n0[0];
		bn_mul_add_word(t.d[0], modulus[0], m, c, p, s);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
		for (j = 1; j < BN_NWORDS; j++) {
			bn_mul_add_word(t.d[j], modulus[j], m, c, p, s);
			t.d[j-1] = t.d[j];
		}
		t.d[BN_NWORDS-1] = tea + c;
		tea = teb + ((t.d[BN_NWORDS-1] < c) ? 1 : 0);
	}

	if (tea || (t.d[BN_NWORDS-1] >= modulus[7])) {
		c = bn_usub_c(r, &t, modulus);
		if (tea || !c)
			return;
	}
	*r = t;
}

void
bn_from_mont(bignum *rb, bignum *b)
{
#define WORKSIZE ((2*BN_NWORDS) + 1)
	bn_word r[WORKSIZE];
	bn_word m, c, p, s;
	int i, j, top;
	/* Copy the input to the working area */
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < BN_NWORDS; i++)
		r[i] = b->d[i];
	/* Zero the upper words */
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = BN_NWORDS; i < WORKSIZE; i++)
		r[i] = 0;
	/* Multiply (long) by modulus */
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < BN_NWORDS; i++) {
		m = r[i] * mont_n0[0];
		c = 0;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
		for (j = 0; j < BN_NWORDS; j++)
			bn_mul_add_word(r[i+j], modulus[j], m, c, p, s);
		r[BN_NWORDS + i] += c;
		if (r[BN_NWORDS + i] < c) {
			if (++r[BN_NWORDS + i + 1] == 0)
				++r[BN_NWORDS + i + 2];  /* The end..? */
		}
	}
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (top = WORKSIZE - 1; ((top > BN_NWORDS) & (r[top] == 0)); top--);
	if (top <= BN_NWORDS) {
		*rb = bn_zero;
		return;
	}
	c = 0;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (j = 0; j < BN_NWORDS; j++)
		bn_subb_word(rb->d[j], r[BN_NWORDS + j], modulus[j], p, c);
	if (c) {
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
		for (j = 0; j < BN_NWORDS; j++)
			rb->d[j] = r[BN_NWORDS + j];
	}
}

/*
 * Modular inversion
 */

void
bn_mod_inverse(bignum *r, bignum *n)
{
	bignum a, b, x, y;
	int shift;
	bn_word xc, yc;
	for (shift = 0; shift < BN_NWORDS; shift++) {
		a.d[shift] = modulus[shift];
		x.d[shift] = 0;
		y.d[shift] = 0;
	}
	b = *n;
	x.d[0] = 1;
	xc = 0;
	yc = 0;
	while (!bn_is_zero(b)) {
		shift = 0;
		while (!bn_is_bit_set(b, shift)) {
			shift++;
			if (bn_is_odd(x))
				xc += bn_uadd_c(&x, &x, modulus);
			bn_rshift1(&x);
			x.d[7] |= (xc << 31);
			xc >>= 1;
		}
		if (shift)
			bn_rshift(&b, shift);

		shift = 0;
		while (!bn_is_bit_set(a, shift)) {
			shift++;
			if (bn_is_odd(y))
				yc += bn_uadd_c(&y, &y, modulus);
			bn_rshift1(&y);
			y.d[7] |= (yc << 31);
			yc >>= 1;
		}
		if (shift)
			bn_rshift(&a, shift);

		if (bn_ucmp(&b, &a) >= 0) {
			xc += yc + bn_uadd(&x, &x, &y);
			bn_usub(&b, &b, &a);
		} else {
			yc += xc + bn_uadd(&y, &y, &x);
			bn_usub(&a, &a, &b);
		}
	}

	if (!bn_is_one(a)) {
		/* no modular inverse */
		*r = bn_zero;
		return;
	}
	/* Compute y % m as cheaply as possible */
	while (yc < 0x80000000)
		yc -= bn_usub_c(&y, &y, modulus);
	bn_neg(&y);
	*r = y;
	return;
}

/*
 * HASH FUNCTIONS
 *
 * BYTE ORDER NOTE: None of the hash functions below deal with byte
 * order.  The caller is expected to be aware of this when it stuffs
 * data into in the native integer.
 *
 * NOTE #2: Endianness of the OpenCL device makes no difference here.
 */

/*
 * SHA-2 256
 *
 * CAUTION: Input buffer will be overwritten/mangled.
 * Data expected in big-endian format.
 * This implementation is designed for space efficiency more than
 * raw speed.
 */

__constant uint sha2_init[8] = {
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
};

__constant uint sha2_k[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

void
sha2_256_init(uint *out)
{
	int i;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < 8; i++)
		out[i] = sha2_init[i];
}

/* The state variable remapping is really contorted */
#define sha2_stvar(vals, i, v) vals[(64+v-i) % 8]

void
sha2_256_block(uint *out, uint *in)
{
	int i;
	uint state[8], s0, s1, t1, t2;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < 8; i++)
		state[i] = out[i];
#ifdef UNROLL_MAX
#pragma unroll 64
#endif
	for (i = 0; i < 64; i++) {
		if (i >= 16) {
			/* Advance the input window */
			t1 = in[(i + 1) % 16];
			t2 = in[(i + 14) % 16];
			in[i % 16] += (in[(i + 9) % 16] +
			     (rotate(t1, 25U) ^ rotate(t1, 14U) ^ (t1 >> 3)) +
			     (rotate(t2, 15U) ^ rotate(t2, 13U) ^ (t2 >> 10)));
		}

		/* Compute the t1, t2 augmentations */
		t1 = sha2_stvar(state, i, 4);
		t2 = sha2_stvar(state, i, 0);
		s0 = (rotate(t2, 30U) ^ rotate(t2, 19U) ^ rotate(t2, 10U));
		s1 = (rotate(t1, 26U) ^ rotate(t1, 21U) ^ rotate(t1, 7U));

		t1 = (sha2_stvar(state, i, 7) + s1 + sha2_k[i] + in[i % 16] +
		      ((t1 & sha2_stvar(state, i, 5)) ^
		       (~t1 & sha2_stvar(state, i, 6))));
		t2 = s0 + ((t2 & sha2_stvar(state, i, 1)) ^
			   (t2 & sha2_stvar(state, i, 2)) ^
			   (sha2_stvar(state, i, 1) & sha2_stvar(state, i, 2)));

		sha2_stvar(state, i, 3) += t1;
		sha2_stvar(state, i, 7) = t1 + t2;
	}
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < 8; i++)
		out[i] += state[i];
}


/*
 * RIPEMD160
 *
 * Data expected in little-endian format.
 */

__constant uint ripemd160_iv[] = {
	0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 };
__constant uint ripemd160_k[] = {
	0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E };
__constant uint ripemd160_kp[] = {
	0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000 };
__constant uchar ripemd160_ws[] = {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
	7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
	3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
	1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
	4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13,
};
__constant uchar ripemd160_wsp[] = {
	5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
	6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
	15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
	8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
	12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11
};
__constant uchar ripemd160_rl[] = {
	11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
	7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
	11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
	11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
	9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6,
};
__constant uchar ripemd160_rlp[] = {
	8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
	9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
	9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
	15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
	8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11
};

#define ripemd160_val(v, i, n) (v)[(80+(n)-(i)) % 5]
#define ripemd160_valp(v, i, n) (v)[5 + ((80+(n)-(i)) % 5)]
#define ripemd160_f0(x, y, z) (x ^ y ^ z)
#define ripemd160_f1(x, y, z) ((x & y) | (~x & z))
#define ripemd160_f2(x, y, z) ((x | ~y) ^ z)
#define ripemd160_f3(x, y, z) ((x & z) | (y & ~z))
#define ripemd160_f4(x, y, z) (x ^ (y | ~z))
#define ripemd160_round(i, in, vals, f, fp, t) do {			\
		ripemd160_val(vals, i, 0) =				\
			rotate(ripemd160_val(vals, i, 0) +		\
			       f(ripemd160_val(vals, i, 1),		\
				 ripemd160_val(vals, i, 2),		\
				 ripemd160_val(vals, i, 3)) +		\
			       in[ripemd160_ws[i]] +			\
			       ripemd160_k[i / 16],			\
			       (uint)ripemd160_rl[i]) +			\
			ripemd160_val(vals, i, 4);			\
		ripemd160_val(vals, i, 2) =				\
			rotate(ripemd160_val(vals, i, 2), 10U);		\
		ripemd160_valp(vals, i, 0) =				\
			rotate(ripemd160_valp(vals, i, 0) +		\
			       fp(ripemd160_valp(vals, i, 1),		\
				  ripemd160_valp(vals, i, 2),		\
				  ripemd160_valp(vals, i, 3)) +		\
			       in[ripemd160_wsp[i]] +			\
			       ripemd160_kp[i / 16],			\
			       (uint)ripemd160_rlp[i]) +		\
			ripemd160_valp(vals, i, 4);			\
		ripemd160_valp(vals, i, 2) =				\
			rotate(ripemd160_valp(vals, i, 2), 10U);	\
	} while (0)

void
ripemd160_init(uint *out)
{
	int i;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for(i = 0; i < 5; i++)
		out[i] = ripemd160_iv[i];
}

void
ripemd160_block(uint *out, uint *in)
{
	uint vals[10], t;
	int i;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < 5; i++)
		vals[i] = vals[i + 5] = out[i];
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < 16; i++)
		ripemd160_round(i, in, vals,
				ripemd160_f0, ripemd160_f4, t);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 16; i < 32; i++)
		ripemd160_round(i, in, vals,
				ripemd160_f1, ripemd160_f3, t);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 32; i < 48; i++)
		ripemd160_round(i, in, vals,
				ripemd160_f2, ripemd160_f2, t);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 48; i < 64; i++)
		ripemd160_round(i, in, vals,
				ripemd160_f3, ripemd160_f1, t);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 64; i < 80; i++)
		ripemd160_round(i, in, vals,
				ripemd160_f4, ripemd160_f0, t);
	t = out[1] + vals[2] + vals[8];
	out[1] = out[2] + vals[3] + vals[9];
	out[2] = out[3] + vals[4] + vals[5];
	out[3] = out[4] + vals[0] + vals[6];
	out[4] = out[0] + vals[1] + vals[7];
	out[0] = t;
}


#ifdef TEST_KERNELS
/*
 * Test kernels
 */

/* Montgomery multiplication test kernel */
__kernel void
test_mul_mont(__global bignum *products_out, __global bignum *nums_in)
{
	bignum a, b, c;
	int o;
	o = get_global_id(0);
	nums_in += (2*o);

	a = nums_in[0];
	b = nums_in[1];
	bn_mul_mont(&c, &a, &b);
	products_out[o] = c;
}

/* modular inversion test kernel */
__kernel void
test_mod_inverse(__global bignum *inv_out, __global bignum *nums_in,
		 int count)
{
	bignum x, xp;
	int i, o;
	o = get_global_id(0) * count;
	for (i = 0; i < count; i++) {
		x = nums_in[o];
		bn_mod_inverse(&xp, &x);
		inv_out[o++] = xp;
	}
}
#endif  /* TEST_KERNELS */


#if 0
__kernel void
calc_addrs(__global uint *hashes_out,
	   __global bignum *z_heap, __global bignum *point_tmp,
	   __global bignum *row_in, __global bignum *col_in, int ncols)
{
	uint hash1[16];
	uint hash2[16];
	uint wl, wh;
	bignum rx, ry;
	bignum x1, y1, a, b, c, d, e, z;
	bn_word cy;
	int i, o;

	/* Load the row increment point */
	o = get_global_id(0);
	rx = col_in[2*o];
	ry = col_in[(2*o) + 1];
	hashes_out += (o * 5 * ncols);
	z_heap += (o * 2 * ncols);
	point_tmp += (o * 2 * ncols);

	/*
	 * Perform the EC point add.
	 * Add the row increment to all row points.
	 * Save the X,Y in the point temporary space.
	 * Save the Z in the z_heap for modular inversion.
	 */
	for (i = 0; i < ncols; i++) {
		x1 = row_in[(2*i)];
		y1 = row_in[(2*i) + 1];

		bn_mod_sub(&z, &x1, &rx);
		z_heap[(ncols - 1) + i] = z;

		bn_mod_sub(&b, &y1, &ry);
		bn_mod_add(&c, &x1, &rx);
		bn_mod_add(&d, &y1, &ry);
		bn_mul_mont(&y1, &b, &b);
		bn_mul_mont(&x1, &z, &z);
		bn_mul_mont(&e, &c, &x1);
		bn_mod_sub(&y1, &y1, &e);
		point_tmp[2*i] = y1;
		bn_mod_lshift1(&y1);
		bn_mod_sub(&y1, &e, &y1);
		bn_mul_mont(&y1, &y1, &b);
		bn_mul_mont(&a, &x1, &z);
		bn_mul_mont(&c, &d, &a);
		bn_mod_sub(&y1, &y1, &c);
		cy = 0;
		if (bn_is_odd(y1))
			cy = bn_uadd_c(&y1, &y1, modulus);
		bn_rshift1(&y1);
		y1.d[BN_NWORDS-1] |= (cy ? 0x80000000 : 0);
		point_tmp[(2*i)+1] = y1;
	}

	/* Compute the product hierarchy in z_heap */
	for (i = ncols - 1; i > 0; i--) {
		a = z_heap[(i*2) - 1];
		b = z_heap[(i*2)];
		bn_mul_mont(&z, &a, &b);
		z_heap[i-1] = z;
	}

	/* Invert the root, fix up 1/ZR -> R/Z */
	z = z_heap[0];
	bn_mod_inverse(&z, &z);

	for (i = 0; i < BN_NWORDS; i++)
		a.d[i] = mont_rr[i];
	bn_mul_mont(&z, &z, &a);
	bn_mul_mont(&z, &z, &a);
	z_heap[0] = z;

	for (i = 1; i < ncols; i++) {
		a = z_heap[i - 1];
		b = z_heap[(i*2) - 1];
		c = z_heap[i*2];
		bn_mul_mont(&z, &a, &c);
		z_heap[(i*2) - 1] = z;
		bn_mul_mont(&z, &a, &b);
		z_heap[i*2] = z;
	}

	for (i = 0; i < ncols; i++) {
		/*
		 * Multiply the coordinates by the inverted Z values.
		 * Stash the coordinates in the hash buffer.
		 * SHA-2 requires big endian, and our intended hash input
		 * is big-endian, so swapping is unnecessary, but
		 * inserting the format byte in front causes a headache.
		 */
		a = z_heap[(ncols - 1) + i];
		bn_mul_mont(&b, &a, &a);  /* Z^2 */
		x1 = point_tmp[2*i];
		bn_mul_mont(&x1, &x1, &b);  /* X / Z^2 */
		bn_from_mont(&x1, &x1);

		wh = 0x00000004;  /* POINT_CONVERSION_UNCOMPRESSED */
		for (o = 0; o < BN_NWORDS; o++) {
			wl = wh;
			wh = x1.d[(BN_NWORDS - 1) - o];
			hash1[o] = (wl << 24) | (wh >> 8);
		}

		bn_mul_mont(&a, &a, &b);  /* Z^3 */
		y1 = point_tmp[(2*i)+1];
		bn_mul_mont(&y1, &y1, &a);  /* Y / Z^3 */
		bn_from_mont(&y1, &y1);

		for (o = 0; o < BN_NWORDS; o++) {
			wl = wh;
			wh = y1.d[(BN_NWORDS - 1) - o];
			hash1[BN_NWORDS + o] = (wl << 24) | (wh >> 8);
		}

		/*
		 * Hash the first 64 bytes of the buffer
		 */
		sha2_256_init(hash2);
		sha2_256_block(hash2, hash1);

		/*
		 * Hash the last byte of the buffer + SHA-2 padding
		 */
		hash1[0] = wh << 24 | 0x800000;
		hash1[1] = 0;
		hash1[2] = 0;
		hash1[3] = 0;
		hash1[4] = 0;
		hash1[5] = 0;
		hash1[6] = 0;
		hash1[7] = 0;
		hash1[8] = 0;
		hash1[9] = 0;
		hash1[10] = 0;
		hash1[11] = 0;
		hash1[12] = 0;
		hash1[13] = 0;
		hash1[14] = 0;
		hash1[15] = 65 * 8;
		sha2_256_block(hash2, hash1);

		/*
		 * Hash the SHA-2 result with RIPEMD160
		 * Unfortunately, SHA-2 outputs big-endian, but
		 * RIPEMD160 expects little-endian.  Need to swap!
		 */
		for (o = 0; o < 8; o++)
			hash2[o] = bswap32(hash2[o]);
		hash2[8] = bswap32(0x80000000);
		hash2[9] = 0;
		hash2[10] = 0;
		hash2[11] = 0;
		hash2[12] = 0;
		hash2[13] = 0;
		hash2[14] = 32 * 8;
		hash2[15] = 0;
		ripemd160_init(hash1);
		ripemd160_block(hash1, hash2);

		/* Copy the hash to the output buffer */
		for (o = 0; o < 5; o++)
			*(hashes_out++) = hash1[o];
	}

}
#endif

#define ACCESS_BUNDLE 1024
#define ACCESS_STRIDE (ACCESS_BUNDLE/BN_NWORDS)

__kernel void
ec_add_grid(__global bn_word *points_out, __global bignum *z_heap, 
	    __global bignum *row_in, __global bignum *col_in)
{
	bignum rx, ry;
	bignum x1, y1, a, b, c, d, e, z;
	bn_word cy;
	int i, cell, start;

	/* Load the row increment point */
	i = 2 * get_global_id(1);
	rx = col_in[i];
	ry = col_in[i+1];

	i = 2 * get_global_id(0);
	x1 = row_in[i];
	y1 = row_in[i+1];

	bn_mod_sub(&z, &x1, &rx);

	z_heap[(2 * get_global_id(1) * get_global_size(0)) +
	       (get_global_size(0) - 1) + get_global_id(0)] = z;

	bn_mod_sub(&b, &y1, &ry);
	bn_mod_add(&c, &x1, &rx);
	bn_mod_add(&d, &y1, &ry);
	bn_mul_mont(&y1, &b, &b);
	bn_mul_mont(&x1, &z, &z);
	bn_mul_mont(&e, &c, &x1);
	bn_mod_sub(&y1, &y1, &e);

	/*
	 * This disgusting code caters to the global memory unit on
	 * various GPUs, by giving it a nice contiguous patch to write
	 * per warp/wavefront.
	 */
	cell = ((get_global_id(1) * get_global_size(0)) + get_global_id(0));
	start = ((((2 * cell) / ACCESS_STRIDE) * ACCESS_BUNDLE) +
		 (cell % (ACCESS_STRIDE/2)));

#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < BN_NWORDS; i++)
		points_out[start + (i*ACCESS_STRIDE)] = y1.d[i];

	bn_mod_lshift1(&y1);
	bn_mod_sub(&y1, &e, &y1);
	bn_mul_mont(&y1, &y1, &b);
	bn_mul_mont(&a, &x1, &z);
	bn_mul_mont(&c, &d, &a);
	bn_mod_sub(&y1, &y1, &c);
	cy = 0;
	if (bn_is_odd(y1))
		cy = bn_uadd_c(&y1, &y1, modulus);
	bn_rshift1(&y1);
	y1.d[BN_NWORDS-1] |= (cy ? 0x80000000 : 0);

	start += (ACCESS_STRIDE/2);
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < BN_NWORDS; i++)
		points_out[start + (i*ACCESS_STRIDE)] = y1.d[i];
}

__kernel void
heap_invert(__global bignum *z_heap, int ncols)
{
	bignum a, b, c, z;
	int i;

	i = get_global_id(0);
	z_heap += (2 * i * ncols);

	/* Compute the product hierarchy in z_heap */
	for (i = ncols - 1; i > 0; i--) {
		a = z_heap[(i*2) - 1];
		b = z_heap[(i*2)];
		bn_mul_mont(&z, &a, &b);
		z_heap[i-1] = z;
	}

	/* Invert the root, fix up 1/ZR -> R/Z */
	bn_mod_inverse(&z, &z);

#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < BN_NWORDS; i++)
		a.d[i] = mont_rr[i];
	bn_mul_mont(&z, &z, &a);
	bn_mul_mont(&z, &z, &a);
	z_heap[0] = z;

	for (i = 1; i < ncols; i++) {
		a = z_heap[i - 1];
		b = z_heap[(i*2) - 1];
		c = z_heap[i*2];
		bn_mul_mont(&z, &a, &c);
		z_heap[(i*2) - 1] = z;
		bn_mul_mont(&z, &a, &b);
		z_heap[i*2] = z;
	}
}

void
hash_ec_point(uint *hash_out, __global bn_word *xy, __global bignum *zip)
{
	uint hash1[16], hash2[16];
	bignum c, zi, zzi;
	bn_word wh, wl;
	int i;

	/*
	 * Multiply the coordinates by the inverted Z values.
	 * Stash the coordinates in the hash buffer.
	 * SHA-2 requires big endian, and our intended hash input
	 * is big-endian, so swapping is unnecessary, but
	 * inserting the format byte in front causes a headache.
	 */
	zi = zip[0];
	bn_mul_mont(&zzi, &zi, &zi);  /* 1 / Z^2 */
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < BN_NWORDS; i++)
		c.d[i] = xy[i*ACCESS_STRIDE];
	bn_mul_mont(&c, &c, &zzi);  /* X / Z^2 */
	bn_from_mont(&c, &c);

	wh = 0x00000004;  /* POINT_CONVERSION_UNCOMPRESSED */
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < BN_NWORDS; i++) {
		wl = wh;
		wh = c.d[(BN_NWORDS - 1) - i];
		hash1[i] = (wl << 24) | (wh >> 8);
	}

	bn_mul_mont(&zzi, &zzi, &zi);  /* 1 / Z^3 */
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < BN_NWORDS; i++)
		c.d[i] = xy[(ACCESS_STRIDE/2) + i*ACCESS_STRIDE];
	bn_mul_mont(&c, &c, &zzi);  /* Y / Z^3 */
	bn_from_mont(&c, &c);

#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < BN_NWORDS; i++) {
		wl = wh;
		wh = c.d[(BN_NWORDS - 1) - i];
		hash1[BN_NWORDS + i] = (wl << 24) | (wh >> 8);
	}

	/*
	 * Hash the first 64 bytes of the buffer
	 */
	sha2_256_init(hash2);
	sha2_256_block(hash2, hash1);

	/*
	 * Hash the last byte of the buffer + SHA-2 padding
	 */
	hash1[0] = wh << 24 | 0x800000;
	hash1[1] = 0;
	hash1[2] = 0;
	hash1[3] = 0;
	hash1[4] = 0;
	hash1[5] = 0;
	hash1[6] = 0;
	hash1[7] = 0;
	hash1[8] = 0;
	hash1[9] = 0;
	hash1[10] = 0;
	hash1[11] = 0;
	hash1[12] = 0;
	hash1[13] = 0;
	hash1[14] = 0;
	hash1[15] = 65 * 8;
	sha2_256_block(hash2, hash1);

	/*
	 * Hash the SHA-2 result with RIPEMD160
	 * Unfortunately, SHA-2 outputs big-endian, but
	 * RIPEMD160 expects little-endian.  Need to swap!
	 */
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < 8; i++)
		hash2[i] = bswap32(hash2[i]);
	hash2[8] = bswap32(0x80000000);
	hash2[9] = 0;
	hash2[10] = 0;
	hash2[11] = 0;
	hash2[12] = 0;
	hash2[13] = 0;
	hash2[14] = 32 * 8;
	hash2[15] = 0;
	ripemd160_init(hash_out);
	ripemd160_block(hash_out, hash2);
}


__kernel void
hash_ec_point_get(__global uint *hashes_out,
		  __global bn_word *points_in, __global bignum *z_heap)
{
	uint hash[5];
	int i, p, cell, start;

	p = get_global_size(0);
	i = p * get_global_id(1);
	z_heap += (i * 2);
	hashes_out += 5 * (i + get_global_id(0));

	cell = ((get_global_id(1) * get_global_size(0)) + get_global_id(0));
	start = ((((2 * cell) / ACCESS_STRIDE) * ACCESS_BUNDLE) +
		 (cell % (ACCESS_STRIDE/2)));
	points_in += start;

	/* Complete the coordinates and hash */
	hash_ec_point(hash, points_in, &z_heap[(p - 1) + get_global_id(0)]);

	/* Output the hash in proper byte-order */
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < 5; i++)
		hashes_out[i] = load_le32(hash[i]);
}

/*
 * Normally this would be one function that compared two hash160s.
 * This one compares a hash160 with an upper and lower bound in one
 * function to work around a problem with AMD's OpenCL compiler.
 */
int
hash160_ucmp_g(uint *a, __global uint *bound)
{
	uint gv;
	int i;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < 5; i++) {
		gv = load_be32(bound[i]);
		if (a[i] < gv) return -1;
		if (a[i] > gv) break;
	}
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < 5; i++) {
		gv = load_be32(bound[5+i]);
		if (a[i] < gv) return 0;
		if (a[i] > gv) return 1;
	}
	return 0;
}

__kernel void
hash_ec_point_search_prefix(__global uint *found,
			    __global bn_word *points_in,
			    __global bignum *z_heap,
			    __global uint *target_table, int ntargets)
{
	uint hash[5];
	int i, high, low, p, cell, start;

	p = get_global_size(0);
	i = p * get_global_id(1);
	z_heap += (i * 2);

	cell = ((get_global_id(1) * get_global_size(0)) + get_global_id(0));
	start = ((((2 * cell) / ACCESS_STRIDE) * ACCESS_BUNDLE) +
		 (cell % (ACCESS_STRIDE/2)));
	points_in += start;

	/* Complete the coordinates and hash */
	hash_ec_point(hash, points_in, &z_heap[(p - 1) + get_global_id(0)]);

	/*
	 * Unconditionally byteswap the hash result, because:
	 * - The byte-level convention of RIPEMD160 is little-endian
	 * - We are comparing it in big-endian order
	 */
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
	for (i = 0; i < 5; i++)
		hash[i] = bswap32(hash[i]);

	/* Binary-search the target table for the hash we just computed */
	for (high = ntargets - 1, low = 0, i = high >> 1;
	     high >= low;
	     i = low + ((high - low) >> 1)) {
		p = hash160_ucmp_g(hash, &target_table[10*i]);
		low = (p > 0) ? (i + 1) : low;
		high = (p < 0) ? (i - 1) : high;
		if (p == 0) {
			/* For debugging purposes, write the hash value */
			found[0] = ((get_global_id(1) * get_global_size(0)) +
				    get_global_id(0));
			found[1] = i;
#ifdef UNROLL_MAX
#pragma unroll UNROLL_MAX
#endif
			for (p = 0; p < 5; p++)
				found[p+2] = load_be32(hash[p]);
			high = -1;
		}
	}
}