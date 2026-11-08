// Stand-in for `grok agent stdio`. Speaks just enough ACP for the adapter test.
import readline from 'node:readline';

const rl = readline.createInterface({ input: process.stdin });
let sessionId;
let promptId;

function send(msg) {
  process.stdout.write(`${JSON.stringify(msg)}\n`);
}

rl.on('line', (line) => {
  const msg = JSON.parse(line);
  if (msg.method === 'initialize') {
    send({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: 1, agentInfo: { version: 'test' } } });
    return;
  }
  if (msg.method === 'session/new') {
    sessionId = 'grok-sess-1';
    send({ jsonrpc: '2.0', id: msg.id, result: { sessionId } });
    return;
  }
  if (msg.method === 'session/load') {
    if (msg.params.sessionId === 'missing') {
      send({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: 'session not found' } });
      return;
    }
    sessionId = msg.params.sessionId;
    send({ jsonrpc: '2.0', id: msg.id, result: { sessionId } });
    return;
  }
  if (msg.method === 'session/prompt') {
    promptId = msg.id;
    const text = msg.params.prompt?.[0]?.text ?? '';
    const reply = async () => {
      if (text.includes('ASK')) {
        send({
          jsonrpc: '2.0',
          id: 50,
          method: 'session/request_permission',
          params: {
            sessionId,
            toolCall: { toolCallId: 'call-1', title: 'Run ls', kind: 'execute', rawInput: { command: 'ls' } },
            options: [
              { optionId: 'allow', kind: 'allow_once', name: 'Allow' },
              { optionId: 'reject', kind: 'reject_once', name: 'Reject' },
            ],
          },
        });
        return;
      }
      send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Hello ' } } } });
      send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'there' } } } });
      send({ jsonrpc: '2.0', id: msg.id, result: { stopReason: 'end_turn' } });
    };
    void reply();
    return;
  }
  if (msg.id !== undefined && msg.result) {
    const allow = msg.result.outcome?.optionId === 'allow';
    send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: allow ? 'allowed' : 'denied' } } } });
    send({ jsonrpc: '2.0', id: promptId, result: { stopReason: 'end_turn' } });
  }
});
