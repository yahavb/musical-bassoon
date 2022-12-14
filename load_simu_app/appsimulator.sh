#!/bin/bash 
#restore simulator state from SQS in the case of previous run
sqs_file="/tmp/"$RANDOM".json"
aws sqs receive-message --queue-url ${QUEUE_URL} > $sqs_file
echo "sqs exit code="$?
if (( $?>0 ))
then
  echo "ERR-SQS"
  j=0.1
else
  receipt_handle=`cat $sqs_file | jq '.Messages[].ReceiptHandle'|sed 's/"//g'`
  j=`cat $sqs_file | jq '.Messages[].Body'|sed 's/"//g'`
  if [ -z "$j" ]
  then
    echo "EMPTY-SQS"
    j=0
  fi
fi
rm -f $sqs_file

prev_inserts=0
prev_updates=0
prev_selects=0
prev_consumes=0

#simulator sine wave range. From $j to 3.14 in 0.1 increments
#0.021 for 24 hours wave length
#0.168 for four hours wave length
_seq=`seq $j 0.168 3.14`
echo "first seq is "$_seq
while true; do
for i in $_seq; do
  sqs_file="/tmp/"$RANDOM".json"
  aws sqs receive-message --queue-url ${QUEUE_URL} > $sqs_file
  if (( $?<=0 )); then
    receipt_handle=`cat $sqs_file | jq '.Messages[].ReceiptHandle'|sed 's/"//g'`
    if [ -n "$receipt_handle" ]; then
      echo "delete msg receipt_handle="$receipt_handle
      aws sqs delete-message --queue-url ${QUEUE_URL} --receipt-handle $receipt_handle
    fi
  fi
  rm -f $sqs_file
  x=`echo $i|awk '{print $1}'`
  sinx=`echo $i|awk '{print int(sin($1)*1200)}'`
  echo "sinx=" $sinx
  echo "i=" $i
  aws sqs send-message --queue-url ${QUEUE_URL} --message-body "$i"

  updates=`echo $(( sinx * 10/4 ))`
  inserts=`echo $(( sinx / 5 / 4 ))`
  selects=`echo $(( sinx / 5 ))`
  consumes=`echo $(( sinx / 5 ))`
  queue_size=`aws sqs get-queue-attributes --queue-url ${APP_QUEUE_URL} --attribute-names ApproximateNumberOfMessages| jq '.Attributes.ApproximateNumberOfMessages'|sed 's/"//g'`
  echo "queue_size="$queue_size
  if (( $queue_size >= 1000 )); then
    updates=`echo $(( updates * 2 ))`
    echo "queue_size was large - more update workers updates="$updates
  fi
  deploys=`kubectl get deploy | grep app| awk '{print $1}'`
  for deploy in $deploys
  do
   if [[ "$deploy" == "django-app"* ]]; then
        kubectl scale deploy/$deploy --replicas=$inserts
        aws cloudwatch put-metric-data --metric-name app_workers --namespace ${DEPLOY_NAME} --value ${inserts} 
        echo "sqs exit code="$?
        echo "inserts="$inserts" sinx="$sinx
   fi
   if [[ "$deploy" == "apploader"* ]]; then
        kubectl scale deploy/$deploy --replicas=$selects
        aws cloudwatch put-metric-data --metric-name load_workers --namespace ${DEPLOY_NAME} --value ${selects} 
        echo "cloudwatch exit code="$?
        echo "selects="$selects" sinx="$sinx
   fi
   if [[ "$deploy" == "appupdate"* ]]; then
        kubectl scale deploy/$deploy --replicas=$updates
        aws cloudwatch put-metric-data --metric-name current_updates --namespace ${DEPLOY_NAME} --value ${updates}
        echo "cloudwatch exit code="$?
        echo "updates="$updates" sinx="$sinx
   fi
   if [[ "$deploy" == "appconsume"* ]]; then
        kubectl scale deploy/$deploy --replicas=$consumes
        aws cloudwatch put-metric-data --metric-name current_consumes --namespace ${DEPLOY_NAME} --value ${consumes} 
        echo "cloudwatch exit code="$?
        echo "consumes="$consumes" sinx="$sinx
   fi
  done

  prev_inserts=$inserts
  prev_updates=$updates
  prev_selects=$selects
  prev_consumes=$consumes

  sleeptime=`awk -v min=$MIN_SLEEP_BETWEEN_CYCLE -v max=$MAX_SLEEP_BETWEEN_CYCLE 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'`
  echo "cleanning not ready nodes and faulty pods"
  kubectl delete po --force `kubectl get po | egrep 'Evicted|CrashLoopBackOff|CreateContainerError|ExitCode|OOMKilled|RunContainerError'|awk '{print $1}'`
  sleep $sleeptime"m"
done
_seq=`seq 0.01 0.168 3.14`
echo "new cycle "$_seq
done
