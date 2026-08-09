#!/usr/bin/env tsx
/**
 * ghql - tiny GitHub GraphQL CLI for RepoBar
 *
 * Examples:
 *   pnpm ghql repo steipete/RepoBar
 *   pnpm ghql contrib steipete --json
 *   pnpm ghql run GraphQL/RepoSnapshot.graphql --vars '{"owner":"steipete","name":"RepoBar"}'
 */

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { Command, Option } from 'commander';
import chalk from 'chalk';
import ora from 'ora';
import { z } from 'zod';
import { requireToken, resolveEndpointConfig } from './github-env';

type GraphQLBody = {
  query: string;
  variables?: Record<string, unknown>;
};

type GraphQLResponse<T> = {
  data?: T;
  errors?: { message: string }[];
};

const root = path.resolve(__dirname, '..');

async function fetchGraphQL<T>(
  body: GraphQLBody,
  endpoint: string,
  token: string
): Promise<{ data: T; rateLimitReset?: number }> {
  const resp = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
      'User-Agent': 'RepoBar-CLI',
    },
    body: JSON.stringify(body),
  });

  const resetHeader = resp.headers.get('x-ratelimit-reset');
  const reset = resetHeader ? Number.parseInt(resetHeader, 10) : undefined;

  const json = (await resp.json()) as GraphQLResponse<T>;
  if (!resp.ok || json.errors?.length) {
    const message = json.errors?.map((e) => e.message).join('; ') ?? resp.statusText;
    throw new Error(`${message} (status ${resp.status})`);
  }
  if (!json.data) {
    throw new Error('Empty GraphQL data');
  }
  return { data: json.data, rateLimitReset: reset };
}

function formatRateLimit(reset?: number): string | undefined {
  if (!reset) return undefined;
  const asDate = new Date(reset * 1000);
  return `rate limit resets ${asDate.toLocaleTimeString()}`;
}

async function loadRepoSnapshotQuery(): Promise<string> {
  const p = path.join(root, 'GraphQL', 'RepoSnapshot.graphql');
  return fs.readFile(p, 'utf8');
}

const contribQuery = `
query UserContributions($login: String!) {
  user(login: $login) {
    contributionsCollection {
      contributionCalendar {
        weeks {
          contributionDays { date contributionCount }
        }
      }
    }
  }
}`;

const program = new Command()
  .name('ghql')
  .description('Lightweight GitHub GraphQL runner for RepoBar debugging')
  .addOption(new Option('--token <token>', 'GitHub token (falls back to GITHUB_TOKEN)'))
  .addOption(
    new Option('--host <url>', 'GraphQL endpoint (default https://api.github.com/graphql)')
  )
  .option('--json', 'Print raw JSON', false)
  .option('--raw', 'Print the raw server response body', false)
  .showHelpAfterError();

program
  .command('repo')
  .argument('<owner/repo>', 'Repository in owner/name form')
  .description('Run RepoSnapshot query to fetch issues, PRs, and latest stable release')
  .action(async (slug: string, opts: Record<string, unknown>, cmd: Command) => {
    const spinner = ora('Fetching repo snapshot').start();
    try {
      const [owner, name] = slug.split('/');
      if (!owner || !name) throw new Error('Use owner/repo format.');

      const query = await loadRepoSnapshotQuery();
      const { graphqlEndpoint, token } = resolveEndpointConfig({
        token: cmd.getOptionValue('token'),
        graphqlHost: cmd.getOptionValue('host'),
      });
      const authedToken = requireToken(token);

      const { data, rateLimitReset } = await fetchGraphQL<{
        repository: {
          name: string;
          latestRelease?: {
            name?: string | null;
            tagName: string;
            publishedAt?: string | null;
            createdAt?: string | null;
            url: string;
            isDraft: boolean;
            isPrerelease: boolean;
            isLatest: boolean;
          } | null;
          issues: { totalCount: number };
          pullRequests: { totalCount: number };
        } | null;
      }>(
        { query, variables: { owner, name } },
        graphqlEndpoint,
        authedToken
      );

      spinner.stop();
      if (program.getOptionValue('json') || cmd.parent?.getOptionValue('json')) {
        console.log(JSON.stringify(data, null, 2));
        return;
      }

      const repo = data.repository;
      if (!repo) throw new Error('Repository not found');
      const release = repo.latestRelease?.isLatest && !repo.latestRelease.isDraft && !repo.latestRelease.isPrerelease
        ? repo.latestRelease
        : undefined;
      const releaseLine = release
        ? `${release.name ?? release.tagName} (${new Date(release.publishedAt ?? release.createdAt ?? 0).toLocaleDateString()})`
        : 'none';

      console.log(
        [
          chalk.bold(`${owner}/${name}`),
          `Issues: ${repo.issues.totalCount}`,
          `PRs: ${repo.pullRequests.totalCount}`,
          `Latest stable release: ${releaseLine}`,
        ].join('\n')
      );
      const rl = formatRateLimit(rateLimitReset);
      if (rl) console.log(chalk.dim(rl));
    } catch (error) {
      spinner.stop();
      console.error(chalk.red((error as Error).message));
      process.exitCode = 1;
    }
  });

program
  .command('contrib')
  .argument('<login>', 'GitHub username')
  .description('Fetch contribution calendar and flatten to day counts')
  .action(async (login: string, _opts, cmd: Command) => {
    const spinner = ora('Fetching contribution calendar').start();
    try {
      const { graphqlEndpoint, token } = resolveEndpointConfig({
        token: cmd.getOptionValue('token'),
        graphqlHost: cmd.getOptionValue('host'),
      });
      const authedToken = requireToken(token);
      const { data, rateLimitReset } = await fetchGraphQL<{
        user: {
          contributionsCollection: {
            contributionCalendar: { weeks: { contributionDays: { date: string; contributionCount: number }[] }[] };
          };
        } | null;
      }>({ query: contribQuery, variables: { login } }, graphqlEndpoint, authedToken);
      spinner.stop();
      const days =
        data.user?.contributionsCollection.contributionCalendar.weeks.flatMap((w) => w.contributionDays) ?? [];

      if (program.getOptionValue('json')) {
        console.log(JSON.stringify(days, null, 2));
      } else {
        const total = days.reduce((sum, d) => sum + d.contributionCount, 0);
        console.log(chalk.bold(`${login}`));
        console.log(`Total contributions: ${total}`);
        console.log(`Days: ${days.length}`);
      }
      const rl = formatRateLimit(rateLimitReset);
      if (rl) console.log(chalk.dim(rl));
    } catch (error) {
      spinner.stop();
      console.error(chalk.red((error as Error).message));
      process.exitCode = 1;
    }
  });

program
  .command('run')
  .argument('<file>', 'Path to .graphql file')
  .option('--vars <json>', 'Variables JSON string', '{}')
  .description('Run an arbitrary GraphQL query')
  .action(async (file: string, opts: { vars: string }, cmd: Command) => {
    const spinner = ora('Running query').start();
    try {
      const query = await fs.readFile(path.resolve(file), 'utf8');
      const vars = z.record(z.string(), z.any()).parse(JSON.parse(opts.vars));
      const { graphqlEndpoint, token } = resolveEndpointConfig({
        token: cmd.getOptionValue('token'),
        graphqlHost: cmd.getOptionValue('host'),
      });
      const authedToken = requireToken(token);
      const { data, rateLimitReset } = await fetchGraphQL<Record<string, unknown>>(
        { query, variables: vars },
        graphqlEndpoint,
        authedToken
      );
      spinner.stop();
      console.log(JSON.stringify(data, null, 2));
      const rl = formatRateLimit(rateLimitReset);
      if (rl) console.log(chalk.dim(rl));
    } catch (error) {
      spinner.stop();
      console.error(chalk.red((error as Error).message));
      process.exitCode = 1;
    }
  });

program.parseAsync(process.argv);
