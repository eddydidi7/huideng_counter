import {SHA256} from 'npm:@noble/hashes@1.8.0/sha2';
// Pin the version: checkpoint representation uses this library's protected state.
// Checkpoints never come from clients; only the service-role RPC stores them.
class CheckpointHash extends SHA256 {
  restore(words:number[], offset:number) {
    if(words.length!==8 || offset%64!==0 || !words.every(Number.isInteger))throw Error('VERIFY_FAILED');
    this.set(...words as [number,number,number,number,number,number,number,number]);
    this.length=offset;this.pos=0;
  }
  snapshot(){if(this.pos!==0)throw Error('VERIFY_FAILED');return this.get();}
}
export const VERIFY_PART_BYTES=8*1024*1024;
export function verifyPart(bytes:Uint8Array, offset:number, size:number, words:number[]|null, expected:string){
 if(bytes.length!==Math.min(VERIFY_PART_BYTES,size-offset)||offset<0||offset%VERIFY_PART_BYTES!==0)throw Error('VERIFY_FAILED');
 const hash=new CheckpointHash();
 if(offset){if(!words)throw Error('VERIFY_FAILED');hash.restore(words,offset);}
 hash.update(bytes);const next=offset+bytes.length;
 if(next===size){const digest=Array.from(hash.digest(),x=>x.toString(16).padStart(2,'0')).join('');if(digest!==expected)throw Error('VERIFY_FAILED');return {offset:next,checksum:digest};}
 return {offset:next,state:hash.snapshot()};
}
