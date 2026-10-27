import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeHarness, tick } from '../helpers/fakes.ts';
import { makePng } from '../helpers/png.ts';
import { buildThreadbareTools } from '../../src/threadbare-mcp.ts';

function fixture() {
  const h = makeHarness();
  const { thread } = h.runner.create({ text: 'Compare these', accountId: 'claude-3' });
  h.adapter.last.init();
  const source = path.join(h.home, 'mockup.png');
  fs.writeFileSync(source, makePng(120, 80));
  const input = { title: 'Account picker', options: [
    { id: 'A', title: 'First', path: source },
    { id: 'B', title: 'Second', path: source },
    { id: 'D', title: 'Reference', path: source, reference: true },
  ] };
  return { h, thread, source, input };
}

test('review imports files, persists draft and stays needsYou after read and restart', () => {
  const {h, thread, source, input} = fixture();
  const {review} = h.runner.createReview(thread.id, input);
  assert.equal(review.options.length, 3);
  assert.notEqual(review.options[0].image.path, source);
  fs.unlinkSync(source);
  assert.ok(fs.existsSync(review.options[0].image.path));
  const saved = h.runner.saveReview(thread.id, review.id, review.revision, {pickedId:'B', notes:{D:'Keep this behaviour'}}).review;
  h.adapter.last.result();
  h.runner.markSeen(thread.id, h.runner.get(thread.id).lastSeq);
  assert.equal(h.runner.get(thread.id).needsYou, true);
  assert.equal(h.runner.get(thread.id).pendingReviews, 1);
  const again = h.restart();
  assert.deepEqual(again.runner.getReview(thread.id, review.id).review.draft, saved.draft);
  assert.equal(again.runner.get(thread.id).needsYou, true);
});

test('review validation leaves no partial card or copied assets', () => {
  const {h,thread,input}=fixture();
  const count=h.runner.events(thread.id).events.length;
  for(const options of [[], [...input.options,{...input.options[0]}], [{...input.options[0], path:'/does/not/exist'}], [{...input.options[0], title:''}], [{...input.options[0], reference:'yes'}]]) {
    assert.throws(()=>h.runner.createReview(thread.id,{...input,options} as any));
  }
  assert.equal(h.runner.events(thread.id).events.length,count);
  assert.equal(h.runner.get(thread.id).pendingReviews,undefined);
});

test('review rejects stale writes, unknown IDs and reference picks, supports notes-only and cancel', () => {
  const {h,thread,input}=fixture();
  const {review}=h.runner.createReview(thread.id,input);
  const saved=h.runner.saveReview(thread.id,review.id,0,{notes:{A:'More room'}}).review;
  assert.throws(()=>h.runner.saveReview(thread.id,review.id,0,{notes:{}}),/changed|revision/i);
  assert.throws(()=>h.runner.respondReview(thread.id,review.id,saved.revision,{pickedId:'D',notes:{}}),/reference/i);
  assert.throws(()=>h.runner.saveReview(thread.id,review.id,saved.revision,{notes:{wrong:'oops'}}),/option/i);
  assert.throws(()=>h.runner.respondReview(thread.id,review.id,saved.revision,{notes:{}}),/pick|note/i);
  const result=h.runner.respondReview(thread.id,review.id,saved.revision,{notes:{D:'Useful with either'}});
  assert.equal(result.review.status,'answered');
  assert.equal(result.review.response?.pickedId,undefined);
  const r2=h.runner.createReview(thread.id,input).review;
  assert.equal(h.runner.cancelReview(thread.id,r2.id,r2.revision).review.status,'cancelled');
  assert.throws(()=>h.runner.saveReview(thread.id,r2.id,1,{notes:{}}),/cancelled/i);
});

test('response queues after busy turn, includes metadata and duplicate retries never send twice', async () => {
  const {h,thread,input}=fixture();
  const {review}=h.runner.createReview(thread.id,input);
  const draft={pickedId:'B',notes:{A:'Too much chrome',D:'Looks good'}};
  const result=h.runner.respondReview(thread.id,review.id,review.revision,draft);
  assert.equal(h.adapter.last.sent.length,1);
  assert.equal(h.store.load(thread.id)?.queue.length,1);
  assert.deepEqual(h.runner.respondReview(thread.id,review.id,review.revision,draft),result);
  assert.throws(()=>h.runner.respondReview(thread.id,review.id,1,{pickedId:'A',notes:{}}),/answered/i);
  h.adapter.last.result(); await tick();
  assert.equal(h.adapter.last.sent.length,2);
  const messages=h.runner.events(thread.id,{limit:1000}).events.filter(e=>e.type==='user.message');
  assert.equal(messages.length,2);
  const reply=messages[1];
  assert.equal(reply.reviewId,review.id);
  assert.deepEqual(reply.reviewResponse,draft);
  assert.match(reply.text,/Account picker/);
  assert.match(reply.text,/Picked B/);
  assert.match(reply.text,/Notes on D/);
  assert.equal(h.runner.get(thread.id).pendingReviews,undefined);
});

test('accepted review reply survives restart before a busy turn finishes', async () => {
  const {h,thread,input}=fixture();
  const {review}=h.runner.createReview(thread.id,input);
  const draft={pickedId:'A',notes:{}};
  const sent=h.runner.respondReview(thread.id,review.id,review.revision,draft);
  const again=h.restart(); await tick();
  assert.deepEqual(again.runner.respondReview(thread.id,review.id,0,draft),sent);
  assert.equal(again.adapter.last.sent.length,1);
  assert.match(again.adapter.last.sent[0].text,/Picked A/);
  assert.equal(again.runner.events(thread.id,{limit:1000}).events.filter(e=>e.type==='user.message'&&e.reviewId===review.id).length,1);
});

test('show_options uses the calling thread and returns a review ID without waiting', async () => {
  const {h,thread,input}=fixture();
  const tool=buildThreadbareTools(h.runner,thread.id).find(t=>t.name==='show_options');
  assert.ok(tool);
  const result=await tool.handler(input as any,{} as any);
  assert.equal(result.isError,undefined);
  assert.match(JSON.stringify(result),/review|choice|later/i);
  assert.equal(h.runner.get(thread.id).pendingReviews,1);
});

test('failed atomic save keeps a review pending, and an accepted outbox repairs a missing card after restart', async () => {
  const {h,thread,input}=fixture();
  const {review}=h.runner.createReview(thread.id,input);
  const save=h.store.save.bind(h.store);
  h.store.save=()=>{throw new Error('disk full')};
  assert.throws(()=>h.runner.respondReview(thread.id,review.id,0,{pickedId:'A',notes:{}}),/disk full/);
  h.store.save=save;
  assert.equal(h.runner.getReview(thread.id,review.id).review.status,'pending');
  assert.equal(h.store.load(thread.id)?.queue.length,0);
  const log=h.store.log(thread.id);
  const append=log.append.bind(log);
  log.append=()=>{throw new Error('event append failed')};
  assert.throws(()=>h.runner.respondReview(thread.id,review.id,0,{pickedId:'A',notes:{}}),/append failed/);
  log.append=append;
  assert.equal(h.store.load(thread.id)?.reviews?.[0].status,'answered');
  const again=h.restart();await tick();
  assert.equal(again.runner.getReview(thread.id,review.id).review.status,'answered');
  assert.equal(again.runner.events(thread.id,{limit:1000}).events.filter(e=>e.type==='review.updated'&&e.review.status==='answered').length,1);
  assert.equal(again.adapter.last.sent.length,1);
});

test('a stale outbox saved before user.message was appended does not replay an already delivered answer', async () => {
  const {h,thread,input}=fixture();
  const {review}=h.runner.createReview(thread.id,input);
  h.runner.respondReview(thread.id,review.id,0,{pickedId:'A',notes:{}});
  const queue=structuredClone(h.store.load(thread.id)!.queue);
  h.adapter.last.result();await tick();
  const rec=h.store.load(thread.id)!;
  rec.queue=queue;h.store.save(rec);
  const again=h.restart();await tick();
  assert.equal(again.adapter.sessions.length,0);
  assert.equal(again.store.load(thread.id)!.queue.length,0);
  assert.equal(again.runner.events(thread.id,{limit:1000}).events.filter(e=>e.type==='user.message'&&e.reviewId===review.id).length,1);
});

test('review RPC methods validate, save, answer and reopen through the authenticated server', async () => {
  const {RpcServer}=await import('../../src/rpc.ts');
  const {RunnerClient}=await import('../../src/client.ts');
  const {nullLogger}=await import('../../src/log.ts');
  const {h,thread,input}=fixture();
  const server=new RpcServer({host:'127.0.0.1',port:0,token:'test-review-token',runner:h.runner,log:nullLogger});
  const {port}=await server.listen();
  const client=await RunnerClient.connect(`ws://127.0.0.1:${port}/rpc`,'test-review-token');
  try {
    await assert.rejects(client.call('reviews.create',{threadId:thread.id,title:'bad',options:[]}), (e:any)=>e.code===-32602);
    const {review}=await client.call('reviews.create',{threadId:thread.id,...input});
    assert.equal((await client.call('reviews.list',{threadId:thread.id})).reviews[0].id,review.id);
    for (const method of ['reviews.get','reviews.list','reviews.cancel']) {
      await assert.rejects(client.call(method,{threadId:42,reviewId:42,revision:0}),(e:any)=>e.code===-32602);
    }
    const saved=await client.call('reviews.save',{threadId:thread.id,reviewId:review.id,revision:review.revision,draft:{pickedId:'B',notes:{A:'Too much'}}});
    assert.equal(saved.review.revision,1);
    await assert.rejects(client.call('reviews.save',{threadId:thread.id,reviewId:review.id,revision:0,draft:{notes:{}}}),(e:any)=>e.code===-32602);
    const answered=await client.call('reviews.respond',{threadId:thread.id,reviewId:review.id,revision:1,draft:saved.review.draft});
    assert.equal(answered.review.status,'answered');
    assert.deepEqual((await client.call('reviews.list',{threadId:thread.id})).reviews,[]);
    const reopened=await client.call('reviews.get',{threadId:thread.id,reviewId:review.id});
    assert.deepEqual(reopened.review.response,saved.review.draft);
    const another=(await client.call('reviews.create',{threadId:thread.id,...input})).review;
    assert.equal((await client.call('reviews.cancel',{threadId:thread.id,reviewId:another.id,revision:0})).review.status,'cancelled');
  } finally {client.close();await server.close();}
});

test('an answered review reconstructs its outbox if queue removal was saved before dispatch', async () => {
  const {h,thread,input}=fixture();
  const {review}=h.runner.createReview(thread.id,input);
  h.runner.respondReview(thread.id,review.id,0,{pickedId:'B',notes:{}});
  const rec=h.store.load(thread.id)!;
  rec.queue=[];h.store.save(rec);
  const again=h.restart();await tick();
  assert.match(again.adapter.last.sent[0].text,/Picked B/);
});

test('show_options is shared with Codex dynamic tools and routes to the runner owning the thread', async () => {
  const {dynamicToolSpecs}=await import('../../src/adapters/codex/tools.ts');
  const {ThreadRouter}=await import('../../src/handover.ts');
  const {h,thread,input}=fixture();
  const tools=buildThreadbareTools(h.runner,thread.id);
  const specs=dynamicToolSpecs(tools);
  assert.match(JSON.stringify(specs),/show_options/);
  const calls:{method:string;params:unknown}[]=[];
  const router=new ThreadRouter(h.runner,()=>({
    owns:(id:string)=>id==='remote-thread',
    call:async(method:string,params:unknown)=>{calls.push({method,params});return {review:{id:'remote-review'}}},
  } as any));
  const reply=await router.createReview('remote-thread',input);
  assert.equal(reply.review.id,'remote-review');
  assert.deepEqual(calls,[{method:'reviews.create',params:{threadId:'remote-thread',...input}}]);
  assert.equal((await router.createReview(thread.id,input)).review.title,input.title);
});

test('review reply survives a failed turn.started append after its user.message was saved', async () => {
  const {h,thread,input}=fixture();
  const {review}=h.runner.createReview(thread.id,input);
  h.adapter.last.result();
  const log=h.store.log(thread.id);
  const append=log.append.bind(log);
  log.append=(event)=>{if(event.type==='turn.started') throw new Error('disk full');append(event)};
  h.runner.respondReview(thread.id,review.id,0,{pickedId:'B',notes:{}});
  assert.equal(h.adapter.last.sent.length,1,'no second message reached the CLI');
  log.append=append;
  const again=h.restart();await tick();
  assert.equal(again.adapter.last.sent.length,1);
  assert.match(again.adapter.last.sent[0].text,/Picked B/);
  assert.equal(again.runner.events(thread.id,{limit:1000}).events.filter(e=>e.type==='user.message'&&e.reviewId===review.id).length,1);
  assert.deepEqual(again.store.load(thread.id)?.reviewDeliveries,[review.id]);
});

test('special option IDs do not invent notes from Object.prototype', () => {
  const {h,thread,input}=fixture();
  input.options[0].id='__proto__';input.options[1].id='constructor';
  const {review}=h.runner.createReview(thread.id,input);
  h.runner.respondReview(thread.id,review.id,0,{pickedId:'constructor',notes:{}});
  const queued=h.store.load(thread.id)!.queue[0];
  assert.match(queued.text,/Picked constructor/);
  assert.doesNotMatch(queued.text,/Notes on|Object|native code/);
});


test('pending reviews list stays oldest-first after draft changes', () => {
  const {h,thread,input}=fixture();
  const first=h.runner.createReview(thread.id,input).review;
  h.clock.advance(1);
  const second=h.runner.createReview(thread.id,input).review;
  h.runner.saveReview(thread.id,first.id,0,{pickedId:'A',notes:{}});
  assert.deepEqual(h.runner.listReviews(thread.id).reviews.map(r=>r.id),[first.id,second.id]);
});

test('a reply whose session.send fails is recovered after restart', async () => {
  const {h,thread,input}=fixture();
  const {review}=h.runner.createReview(thread.id,input);
  h.adapter.last.result();
  h.adapter.last.send=()=>{throw new Error('CLI unavailable')};
  h.runner.respondReview(thread.id,review.id,0,{pickedId:'A',notes:{}});
  await tick();
  assert.equal(h.store.load(thread.id)?.reviewDeliveries,undefined);
  const again=h.restart();await tick();
  assert.match(again.adapter.last.sent[0].text,/Picked A/);
  assert.deepEqual(again.store.load(thread.id)?.reviewDeliveries,[review.id]);
});
