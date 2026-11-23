// Listen on IPv4 and IPv6 and pipe every connection to 127.0.0.1:<target>.
// Orbit's web server and realtime server bind a single address family, while Railway's private network can resolve a service
// name to IPv6 only. Two explicit sockets (the :: one with IPV6_V6ONLY) reach both without depending on the container's sysctl.
//   node dual-forward.mjs <listen-port> <target-port>
import net from 'node:net';

const [listenPort, targetPort] = process.argv.slice(2).map(Number);
if (!listenPort || !targetPort) {
  console.error('usage: dual-forward.mjs <listen-port> <target-port>');
  process.exit(2);
}

function handle(client) {
  const upstream = net.connect(targetPort, '127.0.0.1');
  const close = () => {
    client.destroy();
    upstream.destroy();
  };
  client.on('error', close);
  upstream.on('error', close);
  client.on('close', close);
  upstream.on('close', close);
  client.pipe(upstream);
  upstream.pipe(client);
}

let bound = 0;
for (const [host, ipv6Only] of [['0.0.0.0', false], ['::', true]]) {
  const server = net.createServer(handle);
  server.on('error', (error) => {
    console.error(`[dual-forward] ${host}:${listenPort} ${error.code ?? error.message}`);
    if (host === '0.0.0.0') process.exit(1);
  });
  server.listen({ port: listenPort, host, ipv6Only }, () => {
    bound += 1;
    console.log(`[dual-forward] ${host}:${listenPort} -> 127.0.0.1:${targetPort}`);
  });
}
