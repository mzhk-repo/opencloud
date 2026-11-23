#!/usr/bin/env python3
"""Check the rendered Swarm routing contract with non-secret inputs."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent


class StackRoutingTests(unittest.TestCase):
    def test_routing_and_backend_agree(self):
        env = os.environ.copy()
        env.update(
            OPENCLOUD_IMAGE='opencloudeu/opencloud', OPENCLOUD_IMAGE_TAG='7.2.5',
            OPENCLOUD_DOMAIN='opencloud.example.test',
            ENTRA_TENANT_ID='11111111-1111-4111-8111-111111111111',
            ENTRA_CLIENT_ID='22222222-2222-4222-8222-222222222222',
            OPENCLOUD_PROXY_CONFIG_FILE='./config/proxy.groups.example.yaml',
            OPENCLOUD_YAML_SECRET_NAME='example_secret',
            OPENCLOUD_PROXY_CONFIG_NAME='example_proxy',
            OPENCLOUD_ENTRA_CSP_CONFIG_NAME='example_csp',
            OPENCLOUD_PROXY_NETWORK='example-proxy-net',
        )
        data = json.loads(subprocess.check_output(
            ['docker', 'compose', '-f', 'docker-stack.yml', 'config', '--format', 'json'],
            cwd=ROOT, env=env, stderr=subprocess.DEVNULL,
        ))
        service = data['services']['opencloud']
        self.assertEqual(service['healthcheck']['test'], ['CMD', 'opencloud', 'proxy', 'health'])
        labels = service['deploy']['labels']
        self.assertEqual(service['environment']['PROXY_TLS'], 'false')
        self.assertEqual(service['environment']['OC_URL'], 'https://opencloud.example.test')
        self.assertEqual(labels['traefik.swarm.network'], 'example-proxy-net')
        self.assertEqual(data['networks']['proxy']['name'], 'example-proxy-net')
        self.assertTrue(data['networks']['proxy']['external'])
        self.assertEqual(labels['traefik.http.routers.opencloud.rule'], 'Host(`opencloud.example.test`)')
        self.assertEqual(labels['traefik.http.routers.opencloud.entrypoints'], 'web')
        self.assertEqual(labels['traefik.http.routers.opencloud.service'], 'opencloud')
        self.assertEqual(labels['traefik.http.routers.opencloud.middlewares'], 'opencloud-forwarded-https')
        self.assertEqual(labels['traefik.http.services.opencloud.loadbalancer.server.port'], '9200')
        self.assertEqual(labels['traefik.http.services.opencloud.loadbalancer.server.scheme'], 'http')
        self.assertEqual(labels['traefik.http.middlewares.opencloud-forwarded-https.headers.customrequestheaders.X-Forwarded-Proto'], 'https')
        self.assertEqual(labels['traefik.http.middlewares.opencloud-forwarded-https.headers.customrequestheaders.X-Forwarded-Port'], '443')
        self.assertNotIn('ports', service)
        self.assertFalse(any('buffering' in key.lower() for key in labels))
        self.assertNotIn('traefik.http.routers.opencloud.tls', labels)


if __name__ == '__main__':
    unittest.main()
