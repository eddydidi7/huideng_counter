import {createHash} from 'node:crypto';
import {verifyPart,VERIFY_PART_BYTES} from './verify_stream.ts';
Deno.test('300 MiB SHA-256 survives independent range verification requests',()=>{
 const size=300*1024*1024+73;const block=new Uint8Array(VERIFY_PART_BYTES).fill(7);const hash=createHash('sha256');
 for(let offset=0;offset<size;offset+=block.length)hash.update(block.subarray(0,Math.min(block.length,size-offset)));
 const expected=hash.digest('hex');let state:number[]|null=null;let result;
 for(let offset=0;offset<size;offset+=block.length){result=verifyPart(block.subarray(0,Math.min(block.length,size-offset)),offset,size,state,expected);state=result.state??null;}
 if(result?.checksum!==expected)throw Error('wrong digest');
 let rejected=false;try{verifyPart(new Uint8Array([1,2,3]),0,3,null,expected);}catch{rejected=true;}
 if(!rejected)throw Error('accepted corruption');
});
