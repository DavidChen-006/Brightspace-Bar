#!/usr/bin/env ts-node
import process from 'node:process';

export type EndpointConfig = {
  token: string;
  graphqlEndpoint: string;
  restEndpoint: string;
};

export function resolveEndpointConfig(
  opts: { token?: string; graphqlHost?: string; restHost?: string } = {}
): EndpointConfig {
  const token =
    opts.token ??
    process.env.GITHUB_TOKEN ??
    process.env.GH_TOKEN ??
    process.env.GITHUB_PAT ??
    '';

  const graphqlEndpoint =
    opts.graphqlHost ??
    process.env.GITHUB_GRAPHQL ??
    'https://api.github.com/graphql';

  const restEndpoint =
    opts.restHost ?? process.env.GITHUB_API ?? 'https://api.github.com';

  return { token, graphqlEndpoint, restEndpoint };
}

export function requireToken(token: string): string {
  if (!token) {
    throw new Error(
      'GitHub token is required. Set GITHUB_TOKEN in .env or pass --token.'
    );
  }
  return token;
}
