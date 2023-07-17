from __future__ import absolute_import

import re
import json
import time
import copy
import io
import tempfile
from ast import literal_eval

import pycurl

from WMCore.WMSpec.WMTask import buildLumiMask
from WMCore.DataStructs.LumiList import LumiList
from CRABInterface.DataWorkflow import DataWorkflow
from WMCore.Services.pycurl_manager import ResponseHeader
from WMCore.REST.Error import ExecutionError, InvalidParameter

# WMCore Utils module
from Utils.Throttled import UserThrottle
throttle = UserThrottle(limit=3)

from CRABInterface.Utilities import conn_handler
from ServerUtilities import FEEDBACKMAIL, PUBLICATIONDB_STATES, getEpochFromDBTime
from Databases.FileMetaDataDB.Oracle.FileMetaData.FileMetaData import GetFromTaskAndType

from functools import reduce


JOB_KILLED_HOLD_REASON = "Python-initiated action."

class MissingNodeStatus(ExecutionError):
    pass

class HTCondorDataWorkflow(DataWorkflow):
    """ HTCondor implementation of the status command.
    """

    def logs2(self, workflow, howmany, jobids):
        self.logger.info("About to get log of workflow: %s." % workflow)
        return self.getFiles2(workflow, howmany, jobids, ['LOG'])

    def output2(self, workflow, howmany, jobids):
        self.logger.info("About to get output of workflow: %s." % workflow)
        return self.getFiles2(workflow, howmany, jobids, ['EDM', 'TFILE', 'FAKE'])

    def getFiles2(self, workflow, howmany, jobids, filetype):
        """
        Retrieves the output PFN aggregating output in final and temporary locations.

        :arg str workflow: the unique workflow name
        :arg int howmany: the limit on the number of PFN to return
        :return: a generator of list of outputs"""

        # Looking up task information from the DB
        row = next(self.api.query(None, None, self.Task.ID_sql, taskname = workflow))
        row = self.Task.ID_tuple(*row)

        file_type = 'log' if filetype == ['LOG'] else 'output'

        self.logger.debug("Retrieving the %s files of the following jobs: %s" % (file_type, jobids))
        rows = self.api.query_load_all_rows(None, None, self.FileMetaData.GetFromTaskAndType_sql, filetype = ','.join(filetype), taskname = workflow, howmany = howmany)

        for row in rows:
            yield {'jobid': row[GetFromTaskAndType.JOBID],
                   'lfn': row[GetFromTaskAndType.LFN],
                   'site': row[GetFromTaskAndType.LOCATION],
                   'tmplfn': row[GetFromTaskAndType.TMPLFN],
                   'tmpsite': row[GetFromTaskAndType.TMPLOCATION],
                   'directstageout': row[GetFromTaskAndType.DIRECTSTAGEOUT],
                   'size': row[GetFromTaskAndType.SIZE],
                   'checksum' : {'cksum' : row[GetFromTaskAndType.CKSUM], 'md5' : row[GetFromTaskAndType.ADLER32], 'adler32' : row[GetFromTaskAndType.ADLER32]}
                  }

    def report2(self, workflow, userdn):
        """
        Queries the TaskDB for the webdir, input/output datasets, publication flag.
        Also gets input/output file metadata from the FileMetaDataDB.

        Any other information that the client needs to compute the report is available
        without querying the server.
        """

        res = {}

        ## Get the jobs status first.
        self.logger.info("Fetching report2 information for workflow %s. Getting status first." % (workflow))

        ## Get the information we need from the Task DB.
        row = next(self.api.query(None, None, self.Task.ID_sql, taskname = workflow))
        row = self.Task.ID_tuple(*row)

        outputDatasets = literal_eval(row.output_dataset.read() if row.output_dataset else '[]')
        publication = True if row.publication == 'T' else False

        res['taskDBInfo'] = {"userWebDirURL": row.user_webdir, "inputDataset": row.input_dataset,
                             "outputDatasets": outputDatasets, "publication": publication}

        ## What each job has processed
        ## ---------------------------
        ## Retrieve the filemetadata of output and input files. (The filemetadata are
        ## uploaded by the post-job after stageout has finished for all output and log
        ## files in the job.)
        rows = self.api.query_load_all_rows(None, None, self.FileMetaData.GetFromTaskAndType_sql, filetype='EDM,TFILE,FAKE,POOLIN', taskname=workflow, howmany=-1)
        # Return only the info relevant to the client.
        res['runsAndLumis'] = {}
        for row in rows:
            jobidstr = row[GetFromTaskAndType.JOBID]
            retRow = {'parents': row[GetFromTaskAndType.PARENTS].read(),
                      'runlumi': row[GetFromTaskAndType.RUNLUMI].read(),
                      'events': row[GetFromTaskAndType.INEVENTS],
                      'type': row[GetFromTaskAndType.TYPE],
                      'lfn': row[GetFromTaskAndType.LFN],
                      }
            if jobidstr not in res['runsAndLumis']:
                res['runsAndLumis'][jobidstr] = []
            res['runsAndLumis'][jobidstr].append(retRow)

        yield res

    @throttle.make_throttled()
    @conn_handler(services=['centralconfig'])
    def status(self, workflow, userdn):
        """Retrieve the status of the workflow.

           :arg str workflow: a valid workflow name
           :return: a workflow status summary document"""

        #Empty results
        result = {"status"           : '', #from the db
                  "command"          : '', #from the db
                  "taskFailureMsg"   : '', #from the db
                  "taskWarningMsg"   : [], #from the db
                  "submissionTime"   : 0,  #from the db
                  "statusFailureMsg" : '', #errors of the status itself
                  "jobList"          : [],
                  "schedd"           : '', #from the db
                  "splitting"        : '', #from the db
                  "taskWorker"       : '', #from the db
                  "webdirPath"       : '', #from the db
                  "username"         : ''} #from the db

        # First, verify the task has been submitted by the backend.
        self.logger.info("Got status request for workflow %s" % workflow)
        row = self.api.query(None, None, self.Task.ID_sql, taskname = workflow)
        try:
            #just one row is picked up by the previous query
            row = self.Task.ID_tuple(*next(row))
        except StopIteration:
            raise ExecutionError("Impossible to find task %s in the database." % workflow)

        result['submissionTime'] = getEpochFromDBTime(row.start_time)
        if row.task_command:
            result['command'] = row.task_command

        ## Add scheduler and collector to the result dictionary.
        if row.username:
            result['username'] = row.username
        if row.user_webdir:
            result['webdirPath'] =  '/'.join(['/home/grid']+row.user_webdir.split('/')[-2:])
        if row.schedd:
            result['schedd'] = row.schedd
        if row.twname:
            result['taskWorker'] = row.twname
        if row.split_algo:
            result['splitting'] = row.split_algo

        # 0 - simple crab status
        # 1 - crab status -long
        # 2 - crab status -idle
        self.logger.info("Status result for workflow %s: %s " % (workflow, row.task_status))

        ## Apply taskWarning flag to output.
        taskWarnings = literal_eval(row.task_warnings if isinstance(row.task_warnings, str) else row.task_warnings.read())
        result["taskWarningMsg"] = taskWarnings.decode("utf8") if isinstance(taskWarnings, bytes) else taskWarnings

        ## Helper function to add the task status and the failure message (both as taken
        ## from the Task DB) to the result dictionary.
        def addStatusAndFailureFromDB(result, row):
            result['status'] = row.task_status
            if row.task_failure is not None:
                if isinstance(row.task_failure, str):
                    result['taskFailureMsg'] = row.task_failure
                else:
                    result['taskFailureMsg'] = row.task_failure.read()

        ## Helper function to add a failure message in retrieving the task/jobs status
        ## (and eventually a task status if there was none) to the result dictionary.
        def addStatusAndFailure(result, status, failure = None):
            if not result['status']:
                result['status'] = status
            if failure:
                #if not result['statusFailureMsg']:
                result['statusFailureMsg'] = failure
                #else:
                #    result['statusFailureMsg'] += "\n%s" % (failure)

        #get rid of this? If there is a clusterid we go ahead and get jobs info, otherwise we return result
        self.logger.debug("Cluster id: %s" % row.clusterid)
        if row.task_status in ['NEW', 'HOLDING', 'UPLOADED', 'SUBMITFAILED', 'KILLFAILED', 'RESUBMITFAILED', 'FAILED']:
            addStatusAndFailureFromDB(result, row)
            if row.task_status in ['NEW', 'UPLOADED', 'SUBMITFAILED'] and row.task_command not in ['KILL', 'RESUBMIT']:
                self.logger.debug("Detailed result for workflow %s: %s\n" % (workflow, result))
                return [result]
        #even if we get rid these two should be filled
#                  "taskFailureMsg"   : '', #from the db
#                  "taskWarningMsg"   : [], #from the db

        #here we know we have a clusterid. But what if webdir is not there? return setting a proper statusFailureMsg
        #Now what to do
        #    get node_state/job_log from the schedd. Needs Justas patch (is it ok?)
        #    get error_report
        #    get aso_status (it is going to change once we are done whith the oracle implementation)
        #    combine everything

        ## Here we start to retrieve the jobs statuses.
        jobsPerStatus = {}
        taskJobCount = 0
        taskStatus = {}
        jobList = []
        results = []
        # task_codes are used if condor_q command is done to retrieve task status
        task_codes = {1: 'SUBMITTED', 2: 'SUBMITTED', 4: 'COMPLETED', 5: 'KILLED'}
        # dagman_codes are used if task status retrieved using node_state file
        # 1 = STATUS_READY (Means that task was not yet started)
        # 2 = STATUS_PRERUN (Means that task is doing PRE run)
        # 3 = STATUS_SUBMITTED (Means that task is submitted)
        # 4 = STATUS_POSTRUN (Means that task in PostRun)
        # 5 = STATUS_DONE (Means that task is Done)
        # 6 = STATUS_ERROR (Means that task is Failed/Killed)
        dagman_codes = {1: 'SUBMITTED', 2: 'SUBMITTED', 3: 'SUBMITTED', 4: 'SUBMITTED', 5: 'COMPLETED', 6: 'FAILED'}
        # User web directory is needed for getting files from scheduler.
        if not row.user_webdir :
            self.logger.error("webdir not found in DB. Impossible to retrieve task status")
            addStatusAndFailure(result, status = 'UNKNOWN', failure = 'missing webdir info')
            return [result]
        else:
            self.logger.info("Getting status for workflow %s using node state file.", workflow)
            try:
                taskStatus = self.taskWebStatus({'CRAB_UserWebDir' : row.user_webdir}, result)
                #Check timestamp, if older then 2 minutes warn about stale info
                nodeStateUpd = int(taskStatus.get('DagStatus', {}).get("Timestamp", 0))
                DAGStatus = int(taskStatus.get('DagStatus', {}).get('DagStatus', -1))
                epochTime = int(time.time())
                # If DAGStatus is 5 or 6, it means it is final state and node_state file will not be updated anymore
                # and there is no need to query schedd to get information about task.
                # If not, we check when the last time file was updated. It should update every 30s, which is set in
                # job classad:
                # https://github.com/dmwm/CRABServer/blob/5caac0d379f5e4522f026eeaf3621f7eb5ced98e/src/python/TaskWorker/Actions/DagmanCreator.py#L39
                if (nodeStateUpd > 0 and (int(epochTime - nodeStateUpd) < 120)) or DAGStatus in [5, 6]:
                    self.logger.info("Node state is up to date, using it")
                    taskJobCount = int(taskStatus.get('DagStatus', {}).get('NodesTotal'))
                    self.logger.info(taskStatus)
                    if row.task_status in ['QUEUED', 'KILLED', 'KILLFAILED', 'RESUBMITFAILED', 'FAILED']:
                        result['status'] = row.task_status
                    else:
                        result['status'] = dagman_codes.get(DAGStatus, row.task_status)
                    # make sure taskStatusCode is defined
                    if result['status'] in ['KILLED', 'KILLFAILED']:
                        taskStatusCode = 5
                    else:
                        taskStatusCode = 1
                else:
                    self.logger.info("Node state file is too old or does not have an update time. Stale info is shown")
            except Exception as ee:
                addStatusAndFailure(result, status = 'UNKNOWN', failure = str(ee))
                return [result]

        if 'DagStatus' in taskStatus:
            del taskStatus['DagStatus']

        for i in range(1, taskJobCount+1):
            i = str(i)
            if i not in taskStatus:
                if taskStatusCode == 5:
                    taskStatus[i] = {'State': 'killed'}
                else:
                    taskStatus[i] = {'State': 'unsubmitted'}

        for job, info in taskStatus.items():
            status = info['State']
            jobsPerStatus.setdefault(status, 0)
            jobsPerStatus[status] += 1
            jobList.append((status, job))
        result['jobList'] = jobList
        #result['jobs'] = taskStatus

        if len(taskStatus) == 0 and results and results['JobStatus'] == 2:
            result['status'] = 'Running (jobs not submitted)'

        ## Retrieve publication information.
        publicationInfo = {}
        if (row.publication == 'T' and 'finished' in jobsPerStatus):
            publicationInfo = self.publicationStatus(workflow, row.username)
            self.logger.info("Publication status for workflow %s done", workflow)
        elif (row.publication == 'F'):
            publicationInfo['status'] = {'disabled': []}
        else:
            self.logger.info("No files to publish: Publish flag %s, files transferred: %s" % (row.publication, jobsPerStatus.get('finished', 0)))
        result['publication'] = publicationInfo.get('status', {})
        result['publicationFailures'] = publicationInfo.get('failure_reasons', {})

        ## The output datasets are written into the Task DB by the post-job
        ## when uploading the output files metadata.
        outdatasets = literal_eval(row.output_dataset.read() if row.output_dataset else 'None')
        result['outdatasets'] = outdatasets

        return [result]


    cpu_re = re.compile(r"Usr \d+ (\d+):(\d+):(\d+), Sys \d+ (\d+):(\d+):(\d+)")
    def insertCpu(self, event, info):
        if 'TotalRemoteUsage' in event:
            m = self.cpu_re.match(event['TotalRemoteUsage'])
            if m:
                g = [int(i) for i in m.groups()]
                user = g[0]*3600 + g[1]*60 + g[2]
                sys = g[3]*3600 + g[4]*60 + g[5]
                info['TotalUserCpuTimeHistory'][-1] = user
                info['TotalSysCpuTimeHistory'][-1] = sys
        else:
            if 'RemoteSysCpu' in event:
                info['TotalSysCpuTimeHistory'][-1] = float(event['RemoteSysCpu'])
            if 'RemoteUserCpu' in event:
                info['TotalUserCpuTimeHistory'][-1] = float(event['RemoteUserCpu'])

    @classmethod
    def prepareCurl(cls):
        curl = pycurl.Curl()
        curl.setopt(pycurl.NOSIGNAL, 0)
        curl.setopt(pycurl.TIMEOUT, 30)
        curl.setopt(pycurl.CONNECTTIMEOUT, 30)
        curl.setopt(pycurl.FOLLOWLOCATION, 0)
        curl.setopt(pycurl.MAXREDIRS, 0)
        #curl.setopt(pycurl.ENCODING, 'gzip, deflate')
        return curl

    @classmethod
    def cleanTempFileAndBuff(cls, fp, hbuf):
        """
        Go to the beginning of temp file
        Truncate buffer and file and return
        """
        fp.seek(0)
        fp.truncate(0)
        hbuf.truncate(0)
        return fp, hbuf

    @classmethod
    def myPerform(cls, curl, url):
        try:
            curl.perform()
        except pycurl.error as e:
            raise ExecutionError(("Failed to contact Grid scheduler when getting URL %s. "
                                  "This might be a temporary error, please retry later and "
                                  "contact %s if the error persist. Error from curl: %s"
                                  % (url, FEEDBACKMAIL, str(e))))

    @conn_handler(services=[])
    def publicationStatus(self, workflow, user):
        """Here is what basically the function return, a dict called publicationInfo in the subcalls:
                publicationInfo['status']: something like {'publishing': 0, 'publication_failed': 0, 'not_published': 0, 'published': 5}.
                                           Later on goes into dictresult['publication'] before being returned to the client
                publicationInfo['status']['error']: String containing the error message if not able to contact oracle
                                                    Later on goes into dictresult['publication']['error']
                publicationInfo['failure_reasons']: errors of single files (not yet implemented for oracle..)
        """
        return self.publicationStatusOracle(workflow, user)

    def publicationStatusOracle(self, workflow, user):
        publicationInfo = {}

        #query oracle for the information
        binds = {}
        binds['username'] = user
        binds['taskname'] = workflow
        res = list(self.api.query(None, None, self.transferDB.GetTaskStatusForPublication_sql, **binds))

        #group results by state
        statusDict = {}
        for row in res:
            status = row[2]
            statusStr = PUBLICATIONDB_STATES[status].lower()
            if status != 5:
                statusDict[statusStr] = statusDict.setdefault(statusStr, 0) + 1

        #format and return
        publicationInfo['status'] = statusDict

        #Generic errors (like oracle errors) goes here. N.B.: single files errors should not go here
#        msg = "Publication information for oracle not yet implemented"
#        publicationInfo['status']['error'] = msg

        return publicationInfo


    node_name_re = re.compile("DAG Node: Job(\d+)")
    node_name2_re = re.compile("Job(\d+)")

    def parseASOState(self, fp, nodes, statusResult):
        """ Parse aso_status and for each job change the job status from 'transferring'
            to 'transferred' in case all files in the job have already been successfully
            transferred.

            fp: file pointer to the ASO status file downloaded from the shedd
            nodes: contains the data-structure representing the node state file created by dagman
            statusResult: the dictionary it is going to be returned by the status to the client.
                          we need this to add a warning in case there are jobs missing in the node_state file
        """
        transfers = {}
        data = json.load(fp)
        for docid, result in data['results'].items():
            result = result[0]
            jobid = str(result['jobid'])
            if jobid not in nodes:
                msg = ("It seems one or more jobs are missing from the node_state file."
                       " It might be corrupted as a result of a disk failure on the schedd (maybe it is full?)"
                       " This might be interesting for analysis operation (%s) %" + FEEDBACKMAIL)
                statusResult['taskWarningMsg'] = [msg] + statusResult['taskWarningMsg']
            if jobid in nodes and nodes[jobid]['State'] == 'transferring':
                transfers.setdefault(jobid, {})[docid] = result['state']
            return
        for jobid in transfers:
            ## The aso_status file is created/updated by the post-jobs when monitoring the
            ## transfers, i.e. after all transfer documents for the given job have been
            ## successfully inserted into the ASO database. Thus, if aso_status contains N
            ## documents for a given job_id it means there are exactly N files to transfer
            ## for that job.
            if set(transfers[jobid].values()) == set(['done']):
                nodes[jobid]['State'] = 'transferred'


    @classmethod
    def parseErrorReport(cls, fp, nodes):
        def last(joberrors):
            return joberrors[max(joberrors, key=int)]
        fp.seek(0)
        data = json.load(fp)
        #iterate over the jobs and set the error dict for those which are failed
        for jobid, statedict in nodes.items():
            if 'State' in statedict and statedict['State'] == 'failed' and jobid in data:
                statedict['Error'] = last(data[jobid]) #data[jobid] contains all retries. take the last one


    job_re = re.compile(r"JOB Job(\d+)\s+([A-Z_]+)\s+\((.*)\)")
    post_failure_re = re.compile(r"POST [Ss]cript failed with status (\d+)")
