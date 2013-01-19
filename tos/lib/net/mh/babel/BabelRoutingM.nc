/*
 * Copyright (c) 2012 Martin Cerveny
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

/**
 * The Babel routing protocol implementation module.
 * Handles send and receive Babel protocol messages.
 * Implements "am_address" collision detection and renumbering.
 *
 * @author Martin Cerveny
 */ 

#include "Timer.h"
#include "MH.h"
#include "Babel.h"
#include "Babel_private.h"

#include "debugserial.h"
#if 0 // debug this module
#define xdbg_BABEL(s,args...) printf(#s ": " args)
#define xdbg_inline_BABEL(s, args...) printf(args)
#define xdbg_flush_BABEL(s) printfflush()
#else
#define xdbg_BABEL(s,args...) 
#define xdbg_inline_BABEL(s, args...) 
#define xdbg_flush_BABEL(s) 
#endif

module BabelRoutingM {
	// export
	provides interface RouteSelect;

	provides interface TableReader as NeighborTable;
	provides interface TableReader as RoutingTable;

	uses interface Timer<TMilli> as Timer;
	uses interface Boot;
	uses interface LocalIeeeEui64;

	// L2
	uses interface Packet;
	uses interface AMPacket;

	uses interface AMSend;
	uses interface Receive;

	uses interface SplitControl as AMControl;
	uses interface PacketField<uint8_t> as PacketRSSI;
	uses interface PacketField<uint8_t> as PacketLinkQuality;
	uses interface ActiveMessageAddress;

	// L3
	uses interface Packet as L3Packet;
	uses interface AMPacket as L3AMPacket;

	uses interface Leds;
}
implementation {
	// global state and tables                                                                                                                                                      

	NetDB ndb[BABEL_NDB_SIZE]; // sorted by dest_nodeid
	uint8_t cnt_ndb = 0;
	NeighborDB neighdb[BABEL_NEIGHDB_SIZE]; // sorted by neigh_nodeid
	uint8_t cnt_neighdb = 0;
	uint8_t self;
	AckDB ackdb[BABEL_ACKDB_SIZE]; // FIFO
	uint8_t cnt_ackdb = 0;

	// local state	                                                                                                                                                                                                     

	uint16_t hello_seqno = 0;
	uint16_t hello_interval = BABEL_HELLO_INTERVAL / 8;
	uint16_t hello_timer = BABEL_HELLO_INTERVAL / 8;

	uint16_t nonce = 0;

	uint8_t pending;

	uint8_t wait_cnt = 0;

	//                                                                                                                                                      

	bool busy = FALSE;
	message_t pkt;

	//                          

	am_addr_t block = 0;

	event void Boot.booted() {

		cnt_ndb++;
		self = 0;
		memset(&ndb[self], 0, sizeof(ndb[0]));
		ndb[self].dest_nodeid = call ActiveMessageAddress.amAddress();
		ndb[self].eui = call LocalIeeeEui64.getId();
		ndb[self].flags |= BABEL_FLAG_UPDATE;
		pending |= BABEL_PENDING_HELLO | BABEL_PENDING_UPDATE | BABEL_PENDING_RT_REQUEST_WILD;

		call AMControl.start();
	}

	uint16_t getLqi(message_t * msg) {
		if(call PacketLinkQuality.isSet(msg)) 
			return(uint16_t) call PacketLinkQuality.get(msg);
		else 
			return 0;
	}

	uint16_t getRssi(message_t * msg) {
		if(call PacketRSSI.isSet(msg)) 
			return(uint16_t) call PacketRSSI.get(msg);
		else 
			return 0xFFFF;
	}

	void send();

	event void AMControl.startDone(error_t err) {
		if(err == SUCCESS) {
			call Timer.startPeriodic(10);
			send();
		}
		else {
			call AMControl.start();
		}
	}

	event void AMControl.stopDone(error_t err) {
	}

	uint16_t seqnodiff(uint16_t seqnew, uint16_t seqold) {
		if(seqnew > seqold) 
			return seqnew - seqold;
		else 
			return seqnew + (~ seqold);
	}

	bool seqnograter(uint16_t seqnew, uint16_t seqold, uint16_t maxdiff) {
		uint16_t sq = seqnodiff(seqnew, seqold);
		return(sq > 0)&&(sq < maxdiff);
	}

	uint16_t linkcost(uint16_t hello_history) {
		uint16_t cost = BABEL_LINK_COST * (0x8000 / (((hello_history & 0x8000) >> 2) + ((hello_history & 0x4000) >> 1) + (hello_history & 0x3fff) + 1));
		if(cost > 0x0fff) 
			cost = BABEL_INFINITY;
		return cost;
	}

	bool insert_ndb(NetDB * data) {
		uint8_t b = 0, e = cnt_ndb, m = 0;

		if(cnt_ndb == (sizeof(ndb) / sizeof(ndb[0]))) 
			return FALSE;

		while(e > b) {
			m = (b + e) / 2;
			if(ndb[m].dest_nodeid > data->dest_nodeid) 
				e = m;
			else 
				b = m + 1;
		}

		if(self >= b) 
			self++;
		memmove(&ndb[b + 1], &ndb[b], sizeof(ndb[0]) * (cnt_ndb - b));
		memcpy(&ndb[b], data, sizeof(ndb[0]));
		cnt_ndb++;
		return TRUE;
	}

	void remove_ndb(uint8_t idx) {
		memmove(&ndb[idx], &ndb[idx + 1], sizeof(ndb[0]) * (cnt_ndb - idx - 1));
		if(self > idx) 
			self--;
		cnt_ndb--;
	}

	uint8_t search_ndb(am_addr_t nodeid) {
		uint8_t b = 0, e = cnt_ndb;

		while(e > b) {
			uint8_t m = (b + e) / 2;

			if(ndb[m].dest_nodeid == nodeid) 
				return m;
			if(ndb[m].dest_nodeid > nodeid) 
				e = m;
			else 
				b = m + 1;
		}
		return BABEL_NOT_FOUND;
	}

	bool insert_neighdb(NeighborDB * data) {
		uint8_t b = 0, e = cnt_neighdb, m = 0;

		if(cnt_neighdb == (sizeof(neighdb) / sizeof(neighdb[0]))) 
			return FALSE;

		while(e > b) {
			m = (b + e) / 2;
			if(neighdb[m].neigh_nodeid > data->neigh_nodeid) 
				e = m;
			else 
				b = m + 1;
		}

		memmove(&neighdb[b + 1], &neighdb[b], sizeof(neighdb[0]) * (cnt_neighdb - b));
		memcpy(&neighdb[b], data, sizeof(neighdb[0]));
		cnt_neighdb++;
		return TRUE;
	}

	void remove_neighdb(uint8_t idx) {
		memmove(&neighdb[idx], &neighdb[idx + 1], sizeof(neighdb[0]) * (cnt_neighdb - idx - 1));
		cnt_neighdb--;
	}

	uint8_t search_neighdb(am_addr_t nodeid) {
		uint8_t b = 0, e = cnt_neighdb;

		while(e > b) {
			uint8_t m = (b + e) / 2;

			if(neighdb[m].neigh_nodeid == nodeid) 
				return m;
			if(neighdb[m].neigh_nodeid > nodeid) 
				e = m;
			else 
				b = m + 1;
		}
		return BABEL_NOT_FOUND;
	}

	uint16_t metric(uint16_t m, uint16_t nexthop_nodeid) {
		uint8_t idx;
		uint16_t rx_cost, tx_cost;
		uint32_t etx;

		if(m == BABEL_INFINITY) 
			return BABEL_INFINITY;
		idx = search_neighdb(nexthop_nodeid);
		if(idx == BABEL_NOT_FOUND) 
			return BABEL_INFINITY;
		tx_cost = neighdb[idx].ihu_tx_cost;
		if(tx_cost == BABEL_INFINITY) 
			return BABEL_INFINITY;
		rx_cost = linkcost(neighdb[idx].hello_history);
		if(rx_cost == BABEL_INFINITY) 
			return BABEL_INFINITY;
		etx = (uint32_t) tx_cost * rx_cost;
		if(etx >= BABEL_INFINITY) 
			return BABEL_INFINITY;
		return m + etx + BABEL_RT_COST;
	}

	void send() {
		if(( ! busy)&&(pending)) {
			void * bptr, *aptr;
			uint8_t i;

			aptr = bptr = call Packet.getPayload(&pkt, BABEL_WRITE_MSG_MAX);
			if(bptr) {
				uint16_t destaddr;

				BABEL_WRITE_MSG_BEGIN(bptr, aptr);
				xdbg(BABEL, "txbegin == ");

				if(pending & BABEL_PENDING_ACK) {
					// pending ack response (unicast send)					
					xdbg_inline(BABEL, "tx ack - ");
					if(cnt_ackdb) {
						destaddr = ackdb[0].nodeid;

						BABEL_WRITE_MSG_ACK(bptr, aptr, ackdb[0].nonce);
						memmove(&ackdb[0], &ackdb[1], sizeof(ackdb[0]) * (cnt_ackdb - 1));
						if( ! (--cnt_ackdb)) 
							pending &= ~BABEL_PENDING_ACK;
					}
					else 
						pending &= ~BABEL_PENDING_ACK;
				}
				else {
					destaddr = AM_BROADCAST_ADDR;

					if(pending & BABEL_ADDR_CHANGED) {
						xdbg_inline(BABEL, "upd: nh=%04X oldaddress - ", ndb[self].dest_nodeid);
						BABEL_WRITE_MSG_NH(bptr, aptr, ndb[self].dest_nodeid); // use old nodeid to invalidate routes 
						for(i = 0; i < cnt_ndb;) {
							xdbg_inline(BABEL, "upd: dest=%04X addrchaged (%u,%u)- ", ndb[i].dest_nodeid, i, self);
							if(BABEL_WRITE_MSG_ROUTER_ID(bptr, aptr, ndb[i].eui)&& BABEL_WRITE_MSG_UPDATE(bptr, aptr, 1, ndb[i].seqno, BABEL_INFINITY, ndb[i].dest_nodeid)) {
								if(i != self) 
									remove_ndb(i);
								else 
									i++;
							}
						}
						if(i == 1) {
							// change own address after full route update and reload routing table
							ndb[self].dest_nodeid = call ActiveMessageAddress.amAddress();
							ndb[self].flags |= BABEL_FLAG_UPDATE;
							pending &= ~BABEL_ADDR_CHANGED;
							pending |= BABEL_PENDING_HELLO | BABEL_PENDING_UPDATE | BABEL_PENDING_RT_REQUEST_WILD;
						}
					}
					else {
						// process hello_timer 
						if(pending & BABEL_PENDING_HELLO) {
							xdbg_inline(BABEL, "tx hello seq=%04X - ", hello_seqno);
							pending &= ~BABEL_PENDING_HELLO;
							if(hello_interval < BABEL_HELLO_INTERVAL) {
								hello_interval *= 2;
								if(hello_interval > BABEL_HELLO_INTERVAL) 
									hello_interval = BABEL_HELLO_INTERVAL;
							}
							BABEL_WRITE_MSG_HELLO(bptr, aptr, hello_seqno, hello_interval);
							if((hello_seqno % BABEL_HELLO_PER_IHU) == 0) {
								for(i = 0; i < cnt_neighdb; i++) {
									xdbg_inline(BABEL, "tx ihu %04X - ", neighdb[i].neigh_nodeid);
									if( ! BABEL_WRITE_MSG_IHU(bptr, aptr, linkcost(neighdb[i].hello_history), BABEL_HELLO_PER_IHU * hello_interval, neighdb[i].neigh_nodeid)) {
										xdbg(BABEL, "ihu packet tx overflow error\n");
										break;
									}
								}
							}
							if((hello_seqno % BABEL_HELLO_PER_UPDATE) == 0) {
								for(i = 0; i < cnt_ndb; i++) 
									ndb[i].flags |= BABEL_FLAG_UPDATE;
								pending |= BABEL_PENDING_UPDATE;
							}
						}

						// request full route resync
						if(pending & BABEL_PENDING_RT_REQUEST_WILD) {
							xdbg_inline(BABEL, "tx upd all - ");
							if(BABEL_WRITE_MSG_RT_REQUEST(bptr, aptr, BABEL_RT_WILD)) {
								pending &= ~ BABEL_PENDING_RT_REQUEST_WILD;
							}
						}

						// process route update (maybe more messages) 
						if(pending & BABEL_PENDING_UPDATE) {
							bool more = FALSE;
							xdbg_inline(BABEL, "tx upd - ");
							for(i = 0; i < cnt_ndb; i++) {
								if(ndb[i].flags & BABEL_FLAG_UPDATE) {
									xdbg_inline(BABEL, "upd: dest=%04X seq=%04X metr=%04X - ", ndb[i].dest_nodeid, ndb[i].seqno, (ndb[i].flags & BABEL_FLAG_RETRACTION ? BABEL_INFINITY 
											: ndb[i].metric));
									if(BABEL_WRITE_MSG_ROUTER_ID(bptr, aptr, ndb[i].eui)&& BABEL_WRITE_MSG_UPDATE(bptr, aptr, BABEL_HELLO_PER_UPDATE * hello_interval, ndb[i].seqno,
											(ndb[i].flags & BABEL_FLAG_RETRACTION ? BABEL_INFINITY : ndb[i].metric), ndb[i].dest_nodeid)) {
										ndb[i].flags &= ~ BABEL_FLAG_UPDATE;
									}
									else {
										more = TRUE;
										break;
									}
								}
							}
							if( ! more) 
								pending &= ~ BABEL_PENDING_UPDATE;
						}

						// process sq request (maybe more messages) 
						if(pending & BABEL_PENDING_SQ_REQUEST) {
							bool more = FALSE;
							xdbg_inline(BABEL, "tx sqrq - ");
							for(i = 0; i < cnt_ndb; i++) {
								if(ndb[i].flags & BABEL_FLAG_SQ_REQEST) {
									if(BABEL_WRITE_MSG_SQ_REQUEST(bptr, aptr, ndb[i].pending_seqno, ndb[i].pending_hopcount, ndb[i].eui, ndb[i].dest_nodeid)) {
										ndb[i].flags &= ~ BABEL_FLAG_SQ_REQEST;
										xdbg_inline(BABEL, "sqrq: dest=%04X seq=%04X - ", ndb[i].dest_nodeid, ndb[i].pending_seqno);
									}
									else {
										more = TRUE;
										break;
									}
								}
							}
							if( ! more) 
								pending &= ~ BABEL_PENDING_SQ_REQUEST;
						}

						// process rt request (maybe more messages)
						if(pending & BABEL_PENDING_RT_REQUEST) {
							bool more = FALSE;
							xdbg_inline(BABEL, "tx rtreq - ");
							for(i = 0; i < cnt_ndb; i++) {
								if(ndb[i].flags & BABEL_FLAG_RT_REQUEST) {
									if(BABEL_WRITE_MSG_RT_REQUEST(bptr, aptr, ndb[i].dest_nodeid)) {
										xdbg_inline(BABEL, "rtreq: %04X - ", ndb[i].dest_nodeid);
										ndb[i].flags &= ~ BABEL_FLAG_RT_REQUEST;
									}
									else {
										more = TRUE;
										break;
									}
								}
							}
							if( ! more) 
								pending &= ~ BABEL_PENDING_RT_REQUEST;
						}
					}

					// finish message and send
					if(BABEL_WRITE_MSG_END(bptr, aptr)) {
						if(call AMSend.send(destaddr, &pkt, aptr - bptr) == SUCCESS) {
							busy = TRUE;
							xdbg_inline(BABEL, "== %04X\n", destaddr);
							//call Leds.led0On();
						}
						else {
							xdbg_inline(BABEL, "== %04X ( txerr )\n", destaddr);
						}
					}
					else 
						xdbg(BABEL, "msg len error\n");
					xdbg_flush(BABEL);
				}
			}
		}
	}

	event void AMSend.sendDone(message_t * msg, error_t error) {
		if(&pkt == msg) {
			busy = FALSE;
			xdbg(BABEL, "txdone\n");
			xdbg_flush(BABEL);
			//call Leds.led0Off();
			send();
		}
		else {
			xdbg(BABEL, "txdone err\n");
			xdbg_flush(BABEL);
		}
	}

	event message_t * Receive.receive(message_t * msg, void * payload, uint8_t len) {
		bool send_immediate = FALSE;
		void * bptr = payload, *aptr = payload;
		uint16_t msg_nodeid;

		//		if(block == call AMPacket.source(msg)) {
		//			xdbg(BABEL, "rxbegin %04X== BLOCKED \n", call AMPacket.source(msg));
		//			return msg;
		//		} 

		if(len < 4) {
			xdbg(BABEL, "rx packet too small\n");
			xdbg_flush(BABEL);
			return msg;
		}

		//call Leds.led1On(); 

		xdbg(BABEL, "rxbegin %04X == ", call AMPacket.source(msg));
		msg_nodeid = call AMPacket.source(msg);

		if(BABEL_READ_MSG_BEGIN(bptr, aptr, len)) {
			bool err = FALSE;
			ieee_eui64_t last_eui;
			uint16_t last_nodeid = msg_nodeid;

			while(( ! err)&&( ! BABEL_READ_MSG_END(bptr, aptr, len))) {
				switch(*(nx_uint8_t * ) aptr) {
					case BABEL_PAD1 : // 4.4.1.  Pad1
					{
						xdbg_inline(BABEL, "rx PAD1 - ");
						if( ! BABEL_READ_MSG_PAD1(bptr, aptr, len)) {
							err = TRUE;
							xdbg(BABEL, "rx PAD0 error\n");
						}
						break;
					}
					case BABEL_PADN : // 4.4.2.  PadN
					{
						xdbg_inline(BABEL, "rx PADN - ");
						if( ! BABEL_READ_MSG_PADN(bptr, aptr, len)) {
							err = TRUE;
							xdbg(BABEL, "rx PADN error\n");
						}
						break;
					}
					case BABEL_ACK_REQ : //  4.4.3.  Acknowledgement Request
					{
						uint16_t _nonce, _interval;
						xdbg_inline(BABEL, "rx ACKRQ %04X - ", msg_nodeid);
						if( ! BABEL_READ_MSG_ACK_REQ(bptr, aptr, len, _nonce, _interval)) {
							err = TRUE;
							xdbg(BABEL, "rx ACK REQ error\n");
						}
						else {
							uint8_t i;
							xdbg_inline(BABEL, "ackrq: non=%04X - ", _nonce);
							for(i = 0; i < cnt_ackdb; i++){	// ignore duplicities
								if((ackdb[i].nodeid == msg_nodeid)&&(ackdb[i].nonce == _nonce)) 
									break;
							}
							if(i == cnt_ackdb) {
								if(cnt_ackdb < sizeof(ackdb)) {
									cnt_ackdb++;
									ackdb[i].nodeid = msg_nodeid;
									ackdb[i].nonce = _nonce;
									pending |= BABEL_PENDING_ACK;
									send_immediate = TRUE;
								}
								else {
									err = TRUE;
									xdbg(BABEL, "ackdb overflow error\n");
									break;
								}
							}
						}
						break;
					}
					case BABEL_ACK : //  4.4.4.  Acknowledgement
					{
						uint16_t _nonce;
						xdbg_inline(BABEL, "rx ACK - ");
						if( ! BABEL_READ_MSG_ACK(bptr, aptr, len, _nonce)) {
							err = TRUE;
							xdbg(BABEL, "rx ACK error\n");
						}
						else {
							// TODO: process ack response
							xdbg_inline(BABEL, "ack: non=%04X (UNPROCESSED) - ", _nonce);
						}
						break;
					}
					case BABEL_HELLO : // 4.4.5.  Hello
					{
						uint16_t _seqno, _interval;
						xdbg_inline(BABEL, "rx HELLO - ");
						if( ! BABEL_READ_MSG_HELLO(bptr, aptr, len, _seqno, _interval)) {
							err = TRUE;
							xdbg(BABEL, "rx HELLO error\n");
						}
						else {
							uint8_t idx = search_neighdb(msg_nodeid);
							xdbg_inline(BABEL, "hello: seq=%04X - ", _seqno);
							if(idx != BABEL_NOT_FOUND) {
								uint16_t hello_history = neighdb[idx].hello_history;
								uint8_t hello_timer_lost = 0, i;
								uint16_t hello_seqno_lost;

								// count hello lost by expired hellp_timer
								for(i = 0; i < 16; i++) {
									if( ! (hello_history & 0x8000)) 
										hello_timer_lost++;
									else 
										break;
									hello_history <<= 1;
								}

								// eval seqno
								hello_seqno_lost = seqnodiff(_seqno, neighdb[idx].hello_seqno);

								if(hello_seqno_lost > 16){ // large lost
									neighdb[idx].hello_history = 0;
								}
								else {
									if(hello_timer_lost < hello_seqno_lost) {
										neighdb[idx].hello_history >>= hello_seqno_lost - hello_timer_lost;
									}
									else {
										neighdb[idx].hello_history <<= hello_timer_lost - hello_seqno_lost;
									}
								}

								neighdb[idx].hello_history |= 0x8000;
								neighdb[idx].hello_seqno = _seqno;
								neighdb[idx].hello_timer = 2 * _interval;
								xdbg_inline(BABEL, "hello: history=%04X - ", neighdb[idx].hello_history);
							}
							else {
								NeighborDB data;

								data.neigh_nodeid = msg_nodeid;
								data.hello_history = 0x8000;
								data.hello_seqno = _seqno;
								data.hello_timer = 2 * _interval;
								data.hello_interval = _interval;
								data.ihu_tx_cost = BABEL_INFINITY;
								data.ihu_timer = 0;

								if(insert_neighdb(&data)) {
									uint8_t i;
									xdbg_inline(BABEL, "hello: new - ");
									for(i = 0; i < cnt_ndb; i++) 
										ndb[i].flags |= BABEL_FLAG_UPDATE;
									pending |= BABEL_PENDING_HELLO | BABEL_PENDING_UPDATE;
									hello_interval = BABEL_HELLO_INTERVAL / 8;
								}
								else {
									err = TRUE;
									xdbg(BABEL, "neighdb overflow rx error\n");
									break;
								}
							}
						}
						break;
					}
					case BABEL_IHU : // 4.4.6.  IHU
					{
						uint16_t _cost, _interval, _nodeid;
						xdbg_inline(BABEL, "rx IHU - ");
						if( ! BABEL_READ_MSG_IHU(bptr, aptr, len, _cost, _interval, _nodeid)) {
							err = TRUE;
							xdbg(BABEL, "rx IHU error\n");
						}
						else {
							if(_nodeid == ndb[self].dest_nodeid){	// process only our IHU message data
								uint8_t idx = search_neighdb(msg_nodeid);
								xdbg_inline(BABEL, "ihu: my txcost %d - ", _cost);
								if(idx != BABEL_NOT_FOUND) {
									neighdb[idx].ihu_tx_cost = _cost;
									neighdb[idx].ihu_timer = _interval * BABEL_IHU_THRESHOLD;
								}
								else {
									NeighborDB data;

									data.neigh_nodeid = msg_nodeid;
									data.hello_history = 0x0000;
									data.hello_seqno = 0;
									data.hello_timer = 0;
									data.hello_interval = 0;
									data.ihu_tx_cost = _cost;
									data.ihu_timer = _interval * BABEL_IHU_THRESHOLD;

									if(insert_neighdb(&data)) {
										uint8_t i;
										xdbg_inline(BABEL, "ihu: new neigh - ");
										for(i = 0; i < cnt_ndb; i++) 
											ndb[i].flags |= BABEL_FLAG_UPDATE;
										pending |= BABEL_PENDING_HELLO | BABEL_PENDING_UPDATE;
										hello_interval = BABEL_HELLO_INTERVAL / 8;
									}
									else {
										err = TRUE;
										xdbg(BABEL, "neighdb overflow error\n");
										break;
									}
								}
							}
						}
						break;
					}
					case BABEL_ROUTER_ID : // 4.4.7.  Router-Id
					{
						xdbg_inline(BABEL, "rx RTID - ");
						if( ! BABEL_READ_MSG_ROUTER_ID(bptr, aptr, len, last_eui)) {
							err = TRUE;
							xdbg(BABEL, "rx ROUTERID error\n");
						}
						break;
					}
					case BABEL_NH : // 4.4.8.  Next Hop
					{
						xdbg_inline(BABEL, "rx NH - ");
						if( ! BABEL_READ_MSG_NH(bptr, aptr, len, last_nodeid)) {
							err = TRUE;
							xdbg(BABEL, "rx NH error\n");
						}
						break;
					}
					case BABEL_UPDATE : // 4.4.9.  Update
					{
						uint16_t _interval, _seqno, _metric, _destnodeid;
						xdbg_inline(BABEL, "rx UPD - ");
						if( ! BABEL_READ_MSG_UPDATE(bptr, aptr, len, _interval, _seqno, _metric, _destnodeid)) {
							err = TRUE;
							xdbg(BABEL, "rx UPDATE error\n");
						}
						else {
							uint16_t idx;
							xdbg_inline(BABEL, "upd: dest=%04X seq=%04X metr=%04X - ", _destnodeid, _seqno, _metric);
							if(_destnodeid == ndb[self].dest_nodeid){// reverse echo ?  
								xdbg_inline(BABEL, "upd: me  -");
								if(*(uint64_t * )&last_eui < *(uint64_t * )&ndb[self].eui) {
									am_addr_t new_nodeid = ndb[self].dest_nodeid + 1;
									while((search_ndb(new_nodeid) != BABEL_NOT_FOUND) || (new_nodeid == 0xffff) || (new_nodeid == 0)) 
										new_nodeid++;
									call ActiveMessageAddress.setAddress(TOS_AM_GROUP, new_nodeid);
									xdbg(BABEL, "NODEID collision, new nodeid %04X\n", new_nodeid);
									break;
								}
								if(seqnograter(_seqno, ndb[self].seqno, BABEL_SEQNO_GRATER)) {
									// boot sequence sync to network
									ndb[self].seqno = _seqno + 1;
									ndb[self].flags |= BABEL_FLAG_UPDATE;
									pending |= BABEL_PENDING_UPDATE;
									send_immediate = TRUE;
									xdbg_inline(BABEL, "upd: my NEW seq=%04X -", ndb[self].seqno);
								}
								break;
							}
							idx = search_ndb(_destnodeid);
							if(idx != BABEL_NOT_FOUND) {
								uint16_t m = metric(_metric, last_nodeid);

								if((_metric != BABEL_INFINITY)&&(_seqno == ndb[idx].seqno)&&((m & BABEL_RT_MINOR_BITS_MASK) == (ndb[idx].metric & BABEL_RT_MINOR_BITS_MASK))&&(ndb[idx]
										.nexthop_nodeid == last_nodeid)&&(*(uint64_t * )&ndb[idx].eui == *(uint64_t * )&last_eui)) {
									// equals (seqno, metric, eui), update status for route
									ndb[idx].timer = _interval * BABEL_RT_THRESHOLD;
									ndb[idx].flags &= ~BABEL_FLAG_UNFEASIBLE;
									ndb[idx].flags &= ~(BABEL_FLAG_RT_SWITCH | BABEL_FLAG_RETRACTION);
									xdbg_inline(BABEL, "upd: update - ");
								}
								else {
									if(_metric == BABEL_INFINITY) {
										// received retracted
										if(last_nodeid == ndb[idx].nexthop_nodeid) {
											if(*(uint64_t * )&ndb[idx].eui != *(uint64_t * )&last_eui) {
												// changing eui, cancel sq request
												ndb[idx].eui = last_eui;
												ndb[idx].pending_timer = 0;
												ndb[idx].flags &= ~BABEL_FLAG_SQ_REQEST;
											}
											if(ndb[idx].seqno < _seqno) 
												ndb[idx].seqno = _seqno;
											// send rt request, after timeout try, sq request if any unfeasible received, and go to retracted
											ndb[idx].nexthop_nodeid = BABEL_NODEID_UNDEF; // switch to PHASE 2
											ndb[idx].timer = BABEL_RT_REQUEST_HOLD;
											ndb[idx].flags |= BABEL_FLAG_RT_REQUEST;
											ndb[idx].flags &= ~(BABEL_FLAG_RT_SWITCH | BABEL_FLAG_RETRACTION);
											pending |= BABEL_PENDING_RT_REQUEST;
											send_immediate = TRUE;
											xdbg_inline(BABEL, "upd: retracted - ");
										}
									}
									else {// test feasible
										if(seqnograter(_seqno, ndb[idx].seqno, BABEL_SEQNO_GRATER) || ((_seqno == ndb[idx].seqno)&&(m < ndb[idx].metric))) {
											// feasible - update status for route
											if(*(uint64_t * )&ndb[idx].eui != *(uint64_t * )&last_eui) {
												// changing eui, cancel sq request
												ndb[idx].eui = last_eui;
												ndb[idx].pending_timer = 0;
												ndb[idx].flags &= ~BABEL_FLAG_SQ_REQEST;
												xdbg_inline(BABEL, "upd: remote changed EUI - ");
											}
											if((ndb[idx].pending_timer > 0)&&(seqnodiff(_seqno, ndb[idx].pending_seqno) < BABEL_SEQNO_GRATER)) {
												// this is response to sq request (_seqno >= pending_seqno), cancel sq request
												ndb[idx].pending_timer = 0;
												ndb[idx].flags &= ~BABEL_FLAG_SQ_REQEST;
												xdbg_inline(BABEL, "upd: response to rqsq - ");
											}
											ndb[idx].seqno = _seqno;
											ndb[idx].metric = m;
											ndb[idx].nexthop_nodeid = last_nodeid;
											ndb[idx].timer = _interval * BABEL_RT_THRESHOLD;
											ndb[idx].flags |= BABEL_FLAG_UPDATE;
											ndb[idx].flags &= ~BABEL_FLAG_UNFEASIBLE;
											ndb[idx].flags &= ~(BABEL_FLAG_RT_SWITCH | BABEL_FLAG_RETRACTION);
											pending |= BABEL_PENDING_UPDATE;
											send_immediate = TRUE;
											xdbg_inline(BABEL, "upd: feasible - ");
										}
										else {
											// not feasible
											ndb[idx].flags |= BABEL_FLAG_UNFEASIBLE;
											xdbg_inline(BABEL, "upd: unfeasible - ");
										}
									}
								}
							}
							else {
								// new entry, 3.5.4. /2
								if(_metric != BABEL_INFINITY) {
									NetDB data;

									memset(&data, 0, sizeof(data));
									data.dest_nodeid = _destnodeid;
									data.eui = last_eui;
									data.seqno = _seqno;
									data.metric = metric(_metric, last_nodeid);
									data.nexthop_nodeid = last_nodeid;
									data.timer = _interval * BABEL_RT_THRESHOLD;
									data.flags |= BABEL_FLAG_UPDATE;

									if(insert_ndb(&data)) {
										pending |= BABEL_PENDING_UPDATE;
										send_immediate = TRUE;
										xdbg_inline(BABEL, "upd: new - ");
									}
									else {
										err = TRUE;
										xdbg(BABEL, "ndb overflow error\n");
										break;
									}

								}
							}
						}
						break;
					}
					case BABEL_RT_REQUEST : // 4.4.10.  Route Request
					{
						uint16_t _destnodeid;
						xdbg_inline(BABEL, "rx RTRQ - ");
						if( ! BABEL_READ_MSG_RT_REQUEST(bptr, aptr, len, _destnodeid)) {
							err = TRUE;
							xdbg(BABEL, "rx RT REQUEST error\n");
						}
						else {
							if(_destnodeid == BABEL_RT_WILD) {
								uint8_t i;
								xdbg_inline(BABEL, "rtrq: all - ");
								for(i = 0; i < cnt_ndb; i++) 
									ndb[i].flags |= BABEL_FLAG_UPDATE;
							}
							else {
								uint8_t idx = search_ndb(_destnodeid);
								if(idx != BABEL_NOT_FOUND) {
									xdbg_inline(BABEL, "rtrq: dest=%04X - ", _destnodeid);
									ndb[idx].flags |= BABEL_FLAG_UPDATE;
								}
								else {
									// TODO: send retraction route 3.8.1.1/1 
									// ??? what about loop ?
									xdbg_inline(BABEL, "rtrq: unknown (RETRACTION NOT SEND) - ");
								}
							}
							pending |= BABEL_PENDING_UPDATE;
							send_immediate = TRUE;
						}
						break;
					}
					case BABEL_SQ_REQUEST : // 4.4.11.  Seqno Request
					{
						uint16_t _seqno, _destnodeid;
						uint8_t _hopcount;
						ieee_eui64_t _eui;
						xdbg_inline(BABEL, "rx SQRQ - ");
						if( ! BABEL_READ_MSG_SQ_REQUEST(bptr, aptr, len, _seqno, _hopcount, _eui, _destnodeid)) {
							err = TRUE;
							xdbg(BABEL, "rx SQ REQUEST error\n");
						}
						else {
							xdbg_inline(BABEL, "sqrq: dest=%04X seq=%04X - ", _destnodeid, _seqno);
							if(_destnodeid == ndb[self].dest_nodeid){ // is for me  
								if(*(uint64_t * )&_eui < *(uint64_t * )&ndb[self].eui) {
									am_addr_t new_nodeid = ndb[self].dest_nodeid + 1;
									while((search_ndb(new_nodeid) != BABEL_NOT_FOUND) || (new_nodeid == 0xffff) || (new_nodeid == 0)) 
										new_nodeid++;
									call ActiveMessageAddress.setAddress(TOS_AM_GROUP, new_nodeid);
									xdbg(BABEL, "NODEID collision, new nodeid %04X\n", new_nodeid);
									break;
								}
								if(seqnograter(_seqno, ndb[self].seqno, BABEL_SEQNO_GRATER)) 
									ndb[self].seqno++;
								ndb[self].flags |= BABEL_FLAG_UPDATE;
								pending |= BABEL_PENDING_UPDATE;
								send_immediate = TRUE;
								xdbg_inline(BABEL, "sqrq: my NEW seq=%04X - ", ndb[self].seqno);
							}
							else {
								uint8_t idx = search_ndb(_destnodeid);
								if(idx != BABEL_NOT_FOUND) {
									// 3.8.1.2. /1
									if((ndb[idx].flags & BABEL_FLAG_RETRACTION) || (ndb[idx].metric == BABEL_INFINITY)) 
										break;

									// 3.8.1.2. /2-3
									if(seqnograter(ndb[idx].seqno, _seqno, BABEL_SEQNO_GRATER)){ // have newer in table than requested
										ndb[idx].flags |= BABEL_FLAG_UPDATE;
										pending |= BABEL_PENDING_UPDATE;
										send_immediate = TRUE;
										xdbg_inline(BABEL, "sqrq: update - ");
										break;
									}

									// 3.8.1.2. /4-7, send with broadcast, hopcount barriers infinite broadcast loop 
									if(_hopcount >= 2) {
										_hopcount--;
										// add new or updated sq request
										if((ndb[idx].pending_timer == 0) || seqnograter(_seqno, ndb[idx].pending_seqno, BABEL_SEQNO_GRATER) || ((ndb[idx].pending_seqno == _seqno)&&(ndb[idx]
												.pending_hopcount < _hopcount))) {
											xdbg_inline(BABEL, "sqrq: forward - ");
											ndb[idx].pending_seqno = _seqno;
											ndb[idx].pending_hopcount = _hopcount;
											ndb[idx].pending_timer = BABEL_SQ_REQUEST_RETRY * BABEL_SQ_REQUEST_RETRY_INTERVAL;
											ndb[idx].flags |= BABEL_FLAG_SQ_REQEST;
											pending |= BABEL_PENDING_SQ_REQUEST;
											send_immediate = TRUE;
										}
										break;
									}
									break;
								}
							}
						}
						break;
					}
					default : {
						xdbg_inline(BABEL, "rx uknown - ");
						if( ! BABEL_READ_MSG_UNKNOWN(bptr, aptr, len)) {
							err = TRUE;
							xdbg(BABEL, "rx TLV error\n");
						}
						break;
					}
				}
			}
		}

		xdbg_inline(BABEL, " (node rssi %d)\n", getRssi(msg));
		xdbg_flush(BABEL);

		if(send_immediate) 
			send(); // or post ?                                         

		//call Leds.led1Off(); 

		return msg;
	}

	event void Timer.fired() {
		uint8_t i;

		// process neighdb timers                                                                                   

		for(i = 0; i < cnt_neighdb; i++) {
			if(neighdb[i].hello_timer) 
				if( ! (--neighdb[i].hello_timer)){	// nonfatal lost "hello" 
				neighdb[i].hello_timer = neighdb[i].hello_interval;
				neighdb[i].hello_history >>= 1;
				xdbg(BABEL, "lost hello %04X\n", neighdb[i].neigh_nodeid);
				xdbg_flush(BABEL);
			}
			if(neighdb[i].ihu_timer) 
				if( ! (--neighdb[i].ihu_timer)){	// fatal too many lost "ihu"
				neighdb[i].ihu_tx_cost = BABEL_INFINITY;
				xdbg(BABEL, "lost ihu %04X\n", neighdb[i].neigh_nodeid);
				xdbg_flush(BABEL);
			}
			if((neighdb[i].ihu_tx_cost == BABEL_INFINITY)&&(neighdb[i].hello_history == 0)){ // neighbor lost
				uint8_t j;
				xdbg(BABEL, "neighdb delete %04X\n", neighdb[i].neigh_nodeid);
				xdbg_flush(BABEL);
				// try to switch neigbor in route tables
				for(j = 0; j < cnt_ndb; j++) {
					if(ndb[j].nexthop_nodeid == neighdb[i].neigh_nodeid){ // request update routing
						// switch to PHASE 2
						ndb[j].nexthop_nodeid = BABEL_NODEID_UNDEF;
						ndb[j].timer = BABEL_RT_REQUEST_HOLD;
						ndb[j].flags |= BABEL_FLAG_RT_REQUEST;
						ndb[i].flags &= ~(BABEL_FLAG_RT_SWITCH | BABEL_FLAG_RETRACTION);
						pending |= BABEL_PENDING_RT_REQUEST;
					}
				}
				// delete neigbor
				remove_neighdb(i);
				i--;
			}
		}

		// process ndb timers                                                                                   

		for(i = 0; i < cnt_ndb; i++) {
			if(ndb[i].timer) {
				ndb[i].timer--;
				if(ndb[i].nexthop_nodeid != BABEL_NODEID_UNDEF) {

					if( ! ndb[i].timer){ // route update timeout            

						// PHASE 1: try to change to other feasible route (next_node switch) 
						// BABEL_FLAG_RT_SWITCH           

						if( ! (ndb[i].flags & BABEL_FLAG_RT_SWITCH)) {
							// try to switch route to the next on fly
							// TODO: use free entry in routing table to hold alternative feasible routers and use it here
							ndb[i].timer = BABEL_RT_SWITCH_HOLD;
							ndb[i].flags |= BABEL_FLAG_RT_SWITCH;
							ndb[i].metric |= BABEL_RT_MINOR_BITS_MASK;
						}
						else {
							// SWITCH TO PHASE 2
							// try to switch route to other next_node unsuccessful
							ndb[i].nexthop_nodeid = BABEL_NODEID_UNDEF;
							ndb[i].timer = BABEL_RT_REQUEST_HOLD;
							ndb[i].flags &= ~(BABEL_FLAG_RT_SWITCH | BABEL_FLAG_RETRACTION);
						}
						ndb[i].flags |= BABEL_FLAG_RT_REQUEST;
						pending |= BABEL_PENDING_RT_REQUEST;
					}
				}
				else {

					// PHASE 2: try to find other route with "Request Route"
					// BABEL_NODEID_UNDEF        

					if( ! (ndb[i].flags & BABEL_FLAG_RETRACTION)) {
						// RT request processing (BABEL_RT_REQUEST_HOLD)
						if(ndb[i].timer) {
							if((ndb[i].timer % BABEL_RT_REQUEST_RETRY_INTERVAL) == 0) {
								// retry RT request
								ndb[i].flags |= BABEL_FLAG_RT_REQUEST;
								pending |= BABEL_PENDING_RT_REQUEST;
							}
						}
						else {
							// SWITCH TO PHASE 3
							// RT request unsuccessful
							if(ndb[i].flags & BABEL_FLAG_UNFEASIBLE){ // try to find feasible route with seqno increment if unfeasible exists
								// some unfeasible try SQ request
								// ??? overwrite pending
								ndb[i].pending_seqno = ndb[i].seqno + 1;
								ndb[i].pending_hopcount = BABEL_SQ_REQUEST_HOPCOUNT;
								ndb[i].pending_timer = BABEL_SQ_REQUEST_RETRY * BABEL_SQ_REQUEST_RETRY_INTERVAL;
								ndb[i].flags |= BABEL_FLAG_SQ_REQEST;
								pending |= BABEL_PENDING_SQ_REQUEST;
								xdbg(BABEL, "sqreq dest=%04X seq=%04X\n", ndb[i].dest_nodeid, ndb[i].pending_seqno);
							}
							ndb[i].timer = BABEL_RT_RETRACTION_HOLD;
							// send retraction
							ndb[i].flags |= BABEL_FLAG_UPDATE | BABEL_FLAG_RETRACTION;
							pending |= BABEL_PENDING_UPDATE;
						}
					}
					else {

						// PHASE 3: push retract and wait for "Seqno Request" response
						// BABEL_NODEID_UNDEF && BABEL_FLAG_RETRACTION        

						if(ndb[i].timer) {
							if((ndb[i].timer % BABEL_RT_RETRACTION_RETRY_INTERVAL) == 0) {
								// send retraction
								ndb[i].flags |= BABEL_FLAG_UPDATE;
								pending |= BABEL_PENDING_UPDATE;
							}
						}
						else {

							// PHASE 4: delete
							// last hold timeout, delete from route table (BABEL_RT_REQUEST_HOLD+BABEL_RT_REQUEST_HOLD), 3.5.5. Hold Time        

							xdbg(BABEL, "route delete %04X\n", ndb[i].dest_nodeid);
							remove_ndb(i);
							i--;
						}
					}
				}
			}

			if(ndb[i].pending_timer) {
				if(( ! (--ndb[i].pending_timer))&&(ndb[i].pending_timer % BABEL_SQ_REQUEST_RETRY_INTERVAL) == 0) {
					// retry SQ request
					ndb[i].flags |= BABEL_FLAG_SQ_REQEST;
					pending |= BABEL_PENDING_SQ_REQUEST;
				}
			}
		}

		// process global timer for hello, ihu and periodic update                                                                                  

		if( ! (--hello_timer)) {
			hello_timer = hello_interval;
			hello_seqno++;
			pending |= BABEL_PENDING_HELLO;
		}

		// process pending triggers
		send();
	}

	command mh_action_t RouteSelect.selectRoute(message_t * msg) {

		xdbg(BABEL, "route query: ");
		if(call L3AMPacket.isForMe(msg)) {
			xdbg_inline(BABEL, "RECEIVE\n");
			return MH_RECEIVE;
		}
		else {
			am_addr_t dest_nodeid;
			uint8_t idx;

			dest_nodeid = call L3AMPacket.destination(msg);
			// TODO: where handle broadcast destination ?
			idx = search_ndb(dest_nodeid);

			if(idx == BABEL_NOT_FOUND) {
				xdbg_inline(BABEL, "DISCARD %04X\n", dest_nodeid);
				return MH_DISCARD;
			}
			if(ndb[idx].nexthop_nodeid == BABEL_NODEID_UNDEF) {
				if(wait_cnt++ > 2) {
					ndb[idx].flags |= BABEL_FLAG_RT_REQUEST;
					pending |= BABEL_PENDING_RT_REQUEST;
					wait_cnt = 0;
				}
				xdbg_inline(BABEL, "WAIT %04X (%04X %04X)\n", dest_nodeid, ndb[idx].nexthop_nodeid, ndb[idx].flags);
				return MH_WAIT;
			}

			call AMPacket.setDestination(msg, ndb[idx].nexthop_nodeid);
			xdbg_inline(BABEL, "ROUTE to %04X through %04X\n", dest_nodeid, ndb[idx].nexthop_nodeid);
			return MH_SEND;
		}
	}

	task void addrchanged() {
		xdbg(BABEL, "addr changed %04X\n", call ActiveMessageAddress.amAddress());

		//		switch(call ActiveMessageAddress.amAddress()) {
		//			case 0xE4FC : block = 0xE4C6;
		//			break;
		//			case 0xE4C6 : block = 0xE4FC;
		//			break;
		//			default : break;
		//		}
		//		xdbg(BABEL, "BLOCKING %04X\n", block); 

		pending |= BABEL_ADDR_CHANGED;
		if(call Timer.isRunning())
			// already initialized
		send();
	}

	async event void ActiveMessageAddress.changed() {
		post addrchanged();
	}

	// TABLE searching                    

	command error_t NeighborTable.rowFirst(void * row, uint8_t rowptrsize) {
		if(rowptrsize < sizeof(am_addr_t)) 
			return ESIZE;
		if(cnt_neighdb == 0) 
			return ELAST;
		*(am_addr_t * ) row = neighdb[0].neigh_nodeid;
		return SUCCESS;
	}

	command error_t NeighborTable.rowNext(void * row, uint8_t rowptrsize) {
		uint8_t idx;
		if(rowptrsize < sizeof(am_addr_t)) 
			return ESIZE;
		idx = search_neighdb(*(am_addr_t * ) row);
		if(idx != BABEL_NOT_FOUND) {
			idx++;
			if(idx == cnt_neighdb) 
				return ELAST;
			else {
				*(am_addr_t * ) row = neighdb[idx].neigh_nodeid;
				return SUCCESS;
			}
		}
		else 
			return FAIL;
	}

	command error_t NeighborTable.colRead(void * row, uint8_t col_id, void * col, uint8_t colptrsize) {
		uint8_t idx;
		idx = search_neighdb(*(am_addr_t * ) row);
		if(idx == BABEL_NOT_FOUND) 
			return FAIL;
		switch(col_id) {
			case BABEL_NB_NODEID : {
				if(colptrsize < sizeof(am_addr_t)) 
					return ESIZE;
				*(am_addr_t * ) col = neighdb[idx].neigh_nodeid;
				return SUCCESS;
			}
			case BABEL_NB_COST : {
				if(colptrsize < sizeof(uint16_t)) 
					return ESIZE;
				*(uint16_t * ) col = metric(0, idx);
				return SUCCESS;
			}
			default : return FAIL;
		}
	}

	command error_t RoutingTable.rowFirst(void * row, uint8_t rowptrsize) {
		if(rowptrsize < sizeof(am_addr_t)) 
			return ESIZE;
		if(cnt_ndb == 0) 
			return ELAST;
		*(am_addr_t * ) row = ndb[0].dest_nodeid;
		return SUCCESS;
	}

	command error_t RoutingTable.rowNext(void * row, uint8_t rowptrsize) {
		uint8_t idx;
		if(rowptrsize < sizeof(am_addr_t)) 
			return ESIZE;
		idx = search_ndb(*(am_addr_t * ) row);
		if(idx != BABEL_NOT_FOUND) {
			idx++;
			if(idx == cnt_ndb) 
				return ELAST;
			else {
				*(am_addr_t * ) row = ndb[idx].dest_nodeid;
				return SUCCESS;
			}
		}
		else 
			return FAIL;
	}

	command error_t RoutingTable.colRead(void * row, uint8_t col_id, void * col, uint8_t colptrsize) {
		uint8_t idx;
		idx = search_ndb(*(am_addr_t * ) row);
		if(idx == BABEL_NOT_FOUND) 
			return FAIL;
		switch(col_id) {
			case BABEL_RT_NODEID : {
				if(colptrsize < sizeof(am_addr_t)) 
					return ESIZE;
				*(am_addr_t * ) col = ndb[idx].dest_nodeid;
				return SUCCESS;
			}
			case BABEL_RT_EUI : {
				if(colptrsize < sizeof(ieee_eui64_t)) 
					return ESIZE;
				*(ieee_eui64_t * ) col = ndb[idx].eui;
				return SUCCESS;
			}
			case BABEL_RT_METRIC : {
				if(colptrsize < sizeof(uint16_t)) 
					return ESIZE;
				*(uint16_t * ) col = ndb[idx].metric; // last known metric no retraction
				return SUCCESS;
			}
			case BABEL_RT_NEXT : {
				if(colptrsize < sizeof(am_addr_t)) 
					return ESIZE;
				*(am_addr_t * ) col = ndb[idx].nexthop_nodeid;
				return SUCCESS;
			}
			default : return FAIL;
		}
	}

}