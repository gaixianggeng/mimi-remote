/**
 * 进程内单调递增的先后标记。比较两件事谁先发生时用它，不用毫秒时间戳：同一毫秒里先扫描索引、
 * 再追加 transcript、再读完持有方登记，时间戳相等会把旧扫描误当成足够新（#912）。
 */
let last = 0;

export function nextFreshnessMark(): number {
  last += 1;
  return last;
}
