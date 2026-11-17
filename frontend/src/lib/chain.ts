import { createPublicClient, createWalletClient, custom, fallback, http, type Address, type WalletClient } from "viem";
import { chain } from "../config";

const [main, spare] = chain.rpcUrls.default.http;

export const publicClient = createPublicClient({
  chain,
  transport: fallback([
    // Reads made in the same moment travel as one request, so a chart of thirty past blocks is one call, not thirty.
    http(main, { batch: { batchSize: 40, wait: 20 }, timeout: 15_000, retryCount: 2 }),
    http(spare, { timeout: 15_000, retryCount: 1 }),
  ]),
  batch: { multicall: { wait: 20 } },
});

export type Clients = { publicClient: typeof publicClient; walletClient: WalletClient; account: Address };

type Ethereum = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
  on?: (event: string, handler: (...args: unknown[]) => void) => void;
  removeListener?: (event: string, handler: (...args: unknown[]) => void) => void;
};

export function injected(): Ethereum | undefined {
  return (globalThis as unknown as { ethereum?: Ethereum }).ethereum;
}

/** Asks the browser wallet for an account and moves it to the right network. */
export async function connect(): Promise<Clients> {
  const ethereum = injected();
  if (!ethereum) throw new Error("No browser wallet found. Install one, then reload this page.");
  const accounts = (await ethereum.request({ method: "eth_requestAccounts" })) as Address[];
  if (!accounts.length) throw new Error("The wallet did not share an account.");

  const hexId = `0x${chain.id.toString(16)}`;
  try {
    await ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
  } catch {
    await ethereum.request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId: hexId,
          chainName: chain.name,
          nativeCurrency: chain.nativeCurrency,
          rpcUrls: chain.rpcUrls.default.http,
          blockExplorerUrls: [chain.blockExplorers.default.url],
        },
      ],
    });
  }

  const walletClient = createWalletClient({ account: accounts[0], chain, transport: custom(ethereum) });
  return { publicClient, walletClient, account: accounts[0] };
}
