import { cronJobs } from 'convex/server';
import { internal } from './_generated/api';

const crons = cronJobs();
// Finished commands and paged messages older than a day.
crons.interval('prune old rows', { hours: 6 }, internal.sync.pruneOld, {});
export default crons;
