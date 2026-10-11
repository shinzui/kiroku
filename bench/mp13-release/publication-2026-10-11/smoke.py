"""Smoke the published executables against a new, owned local database."""
import base64,hashlib,http.client,json,os,pathlib,re,signal,socket,subprocess,sys,tempfile,time
out=pathlib.Path(__file__).resolve().parent
bin_dir=pathlib.Path(sys.argv[1])
work=pathlib.Path(tempfile.mkdtemp(prefix='mp13-smoke-',dir='/tmp'))
results={'database_directory':str(work),'responses':{}}
def call(args,name,env=None):
 with (out/(name+'.log')).open('w') as log:subprocess.run(args,stdout=log,stderr=log,check=True,timeout=60,env=env)
def free_port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
pg_port=free_port();server=None;pg_started=False
try:
 call(['initdb','-D',str(work/'db'),'-A','trust','-U','postgres'],'smoke-initdb')
 call(['pg_ctl','-D',str(work/'db'),'-l',str(work/'postgres.log'),'-o',f'-p {pg_port} -k {work} -h 127.0.0.1','-w','start'],'smoke-pg-start');pg_started=True
 env=dict(os.environ,DATABASE_URL=f'postgresql://postgres@127.0.0.1:{pg_port}/postgres')
 call([str(bin_dir/'kiroku-store-migrate'),'up'],'smoke-migrate',env)
 call([str(bin_dir/'kiroku-inspect'),'--help'],'published-inspect-help')
 log=(out/'smoke-inspect.log').open('w')
 server=subprocess.Popen([str(bin_dir/'kiroku-inspect'),'--port','0','--cors-origin','http://localhost:5173'],env=env,stdout=log,stderr=log)
 deadline=time.monotonic()+20
 while time.monotonic()<deadline:
  match=re.search(r'listening on port (\d+)',(out/'smoke-inspect.log').read_text())
  if match:break
  if server.poll() is not None:raise RuntimeError('inspector exited before readiness')
  time.sleep(.1)
 else:raise TimeoutError('inspector readiness')
 port=int(match[1]);results['port']=port
 for path in ['/capabilities','/subscription-checkpoints','/streams','/categories','/events','/subscriptions','/subscriptions/missing/dead-letters','/health/ready']:
  conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5);conn.request('GET',path,headers={'Origin':'http://localhost:5173'});response=conn.getresponse();body=response.read()
  assert response.status==200,(path,response.status,body)
  assert response.getheader('Access-Control-Allow-Origin')=='http://localhost:5173'
  results['responses'][path]={'status':response.status,'body':json.loads(body)};conn.close()
 caps=results['responses']['/capabilities']['body'];assert caps['version']=='0.3.0.0' and all(caps['routes'].values())
 assert results['responses']['/subscriptions']['body']==[]
 with socket.create_connection(('127.0.0.1',port),timeout=5) as ws:
  key=base64.b64encode(os.urandom(16)).decode();ws.sendall((f'GET /ws/events HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nOrigin: http://localhost:5173\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n').encode())
  stream=ws.makefile('rb');status=stream.readline();assert b'101' in status,status
  headers={}
  while True:
   line=stream.readline()
   if line==b'\r\n':break
   k,v=line.decode().split(':',1);headers[k.lower()]=v.strip()
  expected=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode();assert headers['sec-websocket-accept']==expected
  payload=b'{"type":"subscribe_events"}';mask=os.urandom(4);ws.sendall(bytes([0x81,0x80|len(payload)])+mask+bytes(v^mask[i%4] for i,v in enumerate(payload)))
  first,second=stream.read(2);length=second&127
  if length==126:length=int.from_bytes(stream.read(2),'big')
  elif length==127:length=int.from_bytes(stream.read(8),'big')
  frame=json.loads(stream.read(length));assert frame['type']=='event_stream_started',frame
  results['websocket']=frame;ws.sendall(b'\x88\x80'+os.urandom(4));stream.close()
 server.send_signal(signal.SIGTERM);assert server.wait(timeout=10)==0;results['inspector_clean_shutdown']=True;log.close()
finally:
 if server and server.poll() is None:server.terminate();server.wait(timeout=10)
 if pg_started:call(['pg_ctl','-D',str(work/'db'),'-m','fast','-w','stop'],'smoke-pg-stop');results['postgres_stopped']=True
 (out/'published-smoke.json').write_text(json.dumps(results,indent=2)+'\n')
print('Published executable smoke passed; inspector and owned PostgreSQL stopped.')
