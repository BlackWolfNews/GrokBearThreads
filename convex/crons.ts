import { cronJobs } from 'convex/server';
import { internal } from './_generated/api';

const crons = cronJobs();
// Finished commands and paged messages older than a day.
crons.interval('prune old rows', { hours: 6 }, internal.sync.pruneOld, {});
// Share sign-in codes and viewer sign-ins past their time.
crons.interval('prune share sign-ins', { hours: 6 }, internal.share.pruneExpired, {});
export default crons;
