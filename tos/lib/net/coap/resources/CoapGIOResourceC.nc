/*
 * Copyright (c) 2012 University of Patras and 
 * Research Academic Computer Technology Institute & Press Diophantus (CTI)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the
 *   distribution.
 * - Neither the name of the copyright holders nor the names of
 *   its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * @author: Constantinos Marios Angelopoulos
 * @contact: aggeloko@ceid.upatras.gr
 * Adaptation to coap-08:
 * @author: Markus Becker
 */

generic configuration CoapGIOResourceC(uint8_t uri_key) {
  provides interface CoapResource;
  uses interface HplMsp430GeneralIO as GIO0;
  uses interface HplMsp430GeneralIO as GIO1;
  uses interface HplMsp430GeneralIO as GIO2;
  uses interface HplMsp430GeneralIO as GIO3;
} implementation {
  components new CoapGIOResourceP(uri_key) as CoapGIOResourceP;

  CoapResource = CoapGIOResourceP;
  GIO0 = CoapGIOResourceP.GIO0;
  GIO1 = CoapGIOResourceP.GIO1;
  GIO2 = CoapGIOResourceP.GIO2;
  GIO3 = CoapGIOResourceP.GIO3;
}
