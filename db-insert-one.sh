#!/bin/sh

# get photometry and info on a star from vizier catalogues and put them in mysql

# The goal is to arrive at a unique per-star ID based on sexagesimal coordinates in J2000
# at epoch 2000.0, and get photometry from a handful of major catalogues that is matched
# to this ID. Rows from the big tables are downloaded as part of this process, so the
# script checks for existence before going off to vizier. Photometry for a given target
# can then be retrieved simply by grabbing all the rows from the various tables that have
# the desired ID.

# Other photometry, such as Spitzer/Herschel/etc.  where other identifiers, such as
# HD/HIP/2MASS/etc. numbers are given instead of coordinates, can be matched using a
# cross-id table. This is generated by querying simbad

# A major future proofing issue is the ID, which could change if the position or proper
# motion of a target change (i.e. going from PPMXL->Gaia). Anything derived from this ID,
# such as entries in other tables and file names, will then also need to change. Partial
# resolutions are to limit the precision of the ID (e.g. 0.1arcsec) and to use
# bright-star catalogues (HIP,TYC,UCAC4,PPMXL) in preference to Gaia. A more probable
# solution is to rebuild everything for each Gaia release, if that looks necessary. Some
# version control could be incorporated into the ID (e.g. sdb-v1-XXXXXX) to help avoid
# later confusion if duplicate info makes it into the wild.

# script takes name as first arg, which will be looked for with sesame. this can be a set
# of coordinates in 2MASS-style. if two args are given these are assumed to coordinates
# in degrees at epoch 2000.0. these will first be used to look for an object name and a
# more refined set of coordinates, failure meaning that there won't be a list of
# cross-ids and the given coords will be used as given

# TODO: hone shell ninja skills to remove all echo/sed rubbish

# some filenames, include randomness in case we want to run this script in parallel
fp=/tmp/pos$RANDOM.xml
ft=/tmp/tmp$RANDOM.xml
ft2=/tmp/tmp$RANDOM.xml

# database details, user and pass are taken from /etc/my.cnf, and aren't needed for
# direct calls, but are needed explicitly for stilts.
db=sdb
ssl=?useSSL=false
sdb=$db$ssl
tmp=`cat /etc/my.cnf | grep user | sed 's/ //g'`
eval $tmp
tmp=`cat /etc/my.cnf | grep password | sed 's/ //g'`
eval $tmp
mode=append  # set this to dropcreate to start afresh

# other knobs as required
rad=2               # rad is the default match radius in arcsec, greater for GALEX
sdbprefix=sdb-v1-   # prefix for ids
site=fr             # vizquery site

echo "/~~~~~ db-insert-one.sh ~~~~~~/"
echo "Using default match radius of $rad arcsec"
echo "and prefix for sdb ids as $sdbprefix"
echo "and $site mirror for vizquery calls"

# the basic stilts command to use, no -Xms1g -Xmx1g since presumably little memory needed
stilts='/Applications/stilts -classpath /Library/Java/Extensions/mysql-connector-java-5.1.8-bin.jar -Djdbc.drivers=com.mysql.jdbc.Driver'

# if two arguments were given (i.e. coords) try to find a name from simbad, failure
# results in variable "id" being empty
id=$1
if [ $# -eq 2 ]
then
    echo "\nLooking for something at coords: $1 $2"
    id=`curl -s "http://simbad.u-strasbg.fr/simbad/sim-tap/sync?request=doQuery&lang=adql&format=votable&query=SELECT%20top%201%20main_id%20FROM%20basic%20JOIN%20ident%20ON%20oid%20=%20oidref%20WHERE%20CONTAINS(POINT('ICRS',ra,dec),CIRCLE('ICRS',$1,$2,$rad/3600.))=1%20AND%20ra%20IS%20NOT%20NULL%20AND%20dec%20IS%20NOT%20NULL;"  | $stilts tpipe in=- ifmt=votable cmd='random' cmd='keepcols main_id' omode=out out=- ofmt=csv-noheader`
    if [ "$id" != "" ]
    then
	echo "Found id:$id at given coords $1 $2"
    else
	echo "No object found at $1 $2"
    fi
fi

# if given id looks like a coordinate, set this as the id for later matching
if [[ $1 =~ ^J[0-9]{6,}[+-][0-9]{6,} ]]
then
    id=$1
fi

# if one argument was given (i.e. a name) get ra,dec from sesame, if given coords in a
# 2MASS-like format (need at least 9 digits total) then also proceeed. these are
# corrected to epoch 2000.0 (where possible)
if [ "$id" != "" ]
then
    echo "\nsesame using name:$id"
    co=`sesame -rS "$id" | egrep -w 'jradeg|jdedeg'`
    cojoin=${co//[$'\n']/,}
    cojoin=${cojoin//[^0-9+\-,\.]/}
    ra=`echo $cojoin | sed 's/\(.*\),.*/\1/'`
    de=`echo $cojoin | sed 's/.*,\(.*\)/\1/'`
    if [ "$cojoin" == "" ]
    then
	echo "  sesame found nothing for:$1"
	echo "  only id given so nothing to do, exiting"
	exit
    fi
    echo "  sesame got coords:$cojoin"
else
    echo "  no name found, using given coords"
    cojoin=$1,$2
fi
echo "\nFinal set of coords:$cojoin"

# now try to find something at these coords in a table with proper motions, this will
# allow use of epoch-corrected coords when searching for matches in other tables
# below. put in a file to use again below.
echo "\nLooking in proper motion catalogues"

# get multiple tables with the same column format, give tables in order of precision so
# don't sort. tycho2 has pm as floats but others are double which causes problems for
# stilts. assume instead that tyc2 is subsumed into ppmxl and likely to be in tgas
vizquery -site=$site -mime=votable -source=I/337/tgas,I/311/hip2,ppmxl -c.rs=$rad -out.max=1 -out.add=_r -c=$cojoin -out="_RA(J2000,2000.0)" -out="_DE(J2000,2000.0)" -out="*pos.pm;pos.eq.ra" -out="*pos.pm;pos.eq.dec" > $ft2
$stilts tcat in=$ft2 multi=true omode=out ofmt=votable out=$fp

# update coordinates if a pm was found, otherwise try harder with sesame
cotmp=`$stilts tpipe in=$fp ifmt=votable cmd='random' cmd="sort _r" cmd='keepcols "_RAJ2000 _DEJ2000"' cmd="rowrange 1 1" omode=out out=- ofmt=csv-noheader`
if [ "$cotmp" != "" ]
then
    cojoin=$cotmp
    echo "  success, updated epoch 2000.0 coord from pm:$cojoin"
else
    echo "Trying sesame"
    co=`sesame "$id"`
    ok=`echo $co | grep 'pmRA'`
    if [ "$ok" != "" ]
    then
	pmra=`echo $co | sed 's/.*<pmRA>\(.*\)<\/pmRA>.*/\1/'`
	pmde=`echo $co | sed 's/.*<pmDE>\(.*\)<\/pmDE>.*/\1/'`
	echo "  found pm $pmra,$pmde with sesame, keeping original coord:$cojoin"
    else
	echo "  no pm source found, keeping:$cojoin and assuming pm is zero"
	pmra=0.0
	pmde=0.0
    fi

    echo "_r,_raj2000,_dej2000,pmRA,pmDE" > $ft
    echo "-1.0,$cojoin,$pmra,$pmde" >> $ft
    $stilts tpipe in=$ft ifmt=csv cmd='random' omode=out out=- ofmt=votable > $fp
fi

# convert these coords to an ID to be used for this target, need to put coords in a
# temporary file first since stilts can't stream ascii
echo "\nCreating sdb id"
echo ra,dec > $ft
echo $cojoin >> $ft
sdbid=$sdbprefix`$stilts tpipe in=$ft ifmt=csv cmd='random' cmd='replacecol ra degreesToHms(ra,2)' cmd='replacecol dec degreesToDms(dec,1)' omode=out out=- ofmt=csv-noheader | sed "s/://g" | sed "s/,//"`
echo "  source id is:$sdbid"

# finally, see if we have this sbdid already
res=$(mysql $db -N -e "SELECT sdbid FROM xids WHERE xid='$sdbid';")
if [[ $res = $sdbid ]]
then
    echo "\nStopping here, have sdbid $sdbid in xids table"
    exit
else
    echo "\nNew target, going ahead"
fi
mysql $db -e "DELETE FROM xids WHERE sdbid='$sdbid';"

# create temp file with sdbid in it, will use multiple times below including being added
# as a xid. using an ascii table here works better since the header isn't recognised when
# in csv
echo "#sdbid                    xid" > $ft
#     sdb-v1-183656.34+374701.3 bla  # to get spacing right for ascii table
echo $sdbid $sdbid >> $ft

# keep closest row with proper motions for later, add sdbid and rename columns to be
# clearer, grab this back out and update the $fp file
echo "\nWriting proper motion info to db"
$stilts tjoin nin=2 in1=$ft ifmt1=ascii icmd1="keepcols sdbid" in2=$fp ifmt2=votable icmd2="rowrange 1 1" ocmd='random' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=sdb_pm write=$mode
$stilts sqlclient db='jdbc:mysql://localhost/'$sdb user=$user password=$password sql="SELECT * from sdb_pm where sdbid = '$sdbid'" ofmt=votable > $fp

# if we had success with sesame above, use this name to get a list of crossids from
# simbad and some other info, sdbid is the main id
if [ "$id" != "" ]
then
    echo "\nUsing id $id to find xids"
    # xids, remove duplicates that just have different case, sql setup is case-insensitive
    cid=`echo "$id" | sed 's/ /%20/g' | sed 's/+/%2B/g' | sed 's/\*/%2A/g' | sed 's/\[/%5B/g' | sed 's/\]/%5D/g'`
    csdbid=`echo "$sdbid" | sed 's/+/%2B/g'`
    curl -s "http://simbad.u-strasbg.fr/simbad/sim-tap/sync?request=doQuery&lang=adql&format=votable&query=SELECT%20%27$csdbid%27%20as%20sdbid,id2.id%20as%20xid%20FROM%20ident%20AS%20id1%20JOIN%20ident%20AS%20id2%20USING(oidref)%20WHERE%20id1.id=%27$cid%27;" | $stilts tpipe in=- ifmt=votable cmd='random' cmd='addcol xiduc toUpperCase(xid)' cmd='sort xiduc' cmd='uniq xiduc' cmd='delcols xiduc' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=xids write=$mode

    # simbad
    echo "\nUsing id $id to find simbad info"
    curl -s "http://simbad.u-strasbg.fr/simbad/sim-tap/sync?request=doQuery&lang=adql&format=votable&query=SELECT%20basic.main_id,sp_type,sp_bibcode,plx_value,plx_err,plx_bibcode%20FROM%20basic%20JOIN%20ident%20ON%20oidref%20=%20oid%20WHERE%20id=%27$cid%27" > $ft2
    $stilts tjoin nin=2 in1=$ft ifmt1=ascii icmd1='keepcols sdbid' in2=$ft2 ifmt2=votable ocmd='random' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=simbad write=$mode
fi

# sanity check, that no xid matches the given id for another sdbid
res=$(mysql $db -N -e "SELECT sdbid,xid FROM xids WHERE xid='$id' and sdbid != '$sdbid';")
if [ "$res" != "" ]
then
    echo "\nERROR: Found xid for $id different to sdbid: $sdbid"
    exit
fi

# add given id as a xid. this is a potential issue if the given id is not unique. by
# leaving this option on we assume we'll only ever be given unique ids. this should be OK
# as an id will either be a coordinate and so must be fairly precise, or will be
# successfully resolved by sesame, and hence unambiguous.
if [ "$id" != "" -a 1 == 1 ]
then
    # check we don't have it as an xid already
    res=$(mysql $db -N -e "SELECT xid FROM xids WHERE xid='$id';")
    if [ "$res" == "" ]
    then
	echo "\nAdding given id as an xid"
	echo $sdbid \"$id\" >> $ft
    else
	echo "\nNot adding given id as xid, already in list"
    fi
fi
echo "\nUpdating xids to include sbdid"
$stilts tpipe in=$ft ifmt=ascii cmd='random' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=xids write=append

# collect some more crossids that may not exist already, this is used for tables that
# exist in full in the databse already

# IRAS FSC, this catalogue has FK5 positions at epoch 1983.5. assume IRAS ellipse
# uncertainty much larger than search position. grab subset of IRAS within 10deg first
res=$(mysql $db -N -e "SELECT xid FROM xids WHERE sdbid='$sdbid' and xid REGEXP('^IRAS F');")
if [[ $res == "" ]]
then
    echo "\nIRAS FSC ID not present, looking"
    $stilts sqlclient db='jdbc:mysql://localhost/photometry'$ssl user=$user password=$password sql="SELECT * from iras_fsc where _raj2000 between $ra-5.0 and $ra+5.0 and _dej2000 between $de-5.0 and $de+5.0" ofmt=votable > $ft
    $stilts sqlclient db='jdbc:mysql://localhost/'$sdb user=$user password=$password sql="SELECT sdbid,raj2000 + (1983.5-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600. as ra_ep1983p5,dej2000 + (1983.5-2000.0) * pmde/1e3/3600. as de_ep1983p5 from sdb_pm where sdbid = '$sdbid'" ofmt=votable > $ft2
    $stilts tmatch2 in1=$ft2 ifmt1=votable in2=$ft ifmt2=votable ocmd='keepcols "sdbid IRAS_ID"' matcher=skyellipse values1='ra_ep1983p5 de_ep1983p5 1.0 1.0 0.0' values2='_RAJ2000 _DEJ2000 Major Minor PosAng' params='20' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=xids find=best write=append
else
    echo "\nHave IRAS FSC ID:$res"
fi

# IRAS PSC, as above
res=$(mysql $db -N -e "SELECT xid FROM xids WHERE sdbid='$sdbid' and xid REGEXP('^IRAS [0-9]');")
if [[ $res == "" ]]
then
    echo "\nIRAS PSC ID not present, looking"
    $stilts sqlclient db='jdbc:mysql://localhost/photometry'$ssl user=$user password=$password sql="SELECT * from iras_psc where _raj2000 between $ra-5.0 and $ra+5.0 and _dej2000 between $de-5.0 and $de+5.0" ofmt=votable > $ft
    $stilts sqlclient db='jdbc:mysql://localhost/'$sdb user=$user password=$password sql="SELECT sdbid,raj2000 + (1983.5-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600. as ra_ep1983p5,dej2000 + (1983.5-2000.0) * pmde/1e3/3600. as de_ep1983p5 from sdb_pm where sdbid = '$sdbid'" ofmt=votable > $ft2
    $stilts tmatch2 in1=$ft2 ifmt1=votable in2=$ft ifmt2=votable ocmd='keepcols "sdbid IRAS_ID"' matcher=skyellipse values1='ra_ep1983p5 de_ep1983p5 1.0 1.0 0.0' values2='_RAJ2000 _DEJ2000 Major Minor PosAng' params='20' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=xids find=best write=append
else
    echo "\nHave IRAS PSC ID:$res"
fi

#### now do catalogues we're not going to store in their entirety but download as we
#### need. these are sorted roughly in wavelength order

# GALEX All-sky, surveys between early 2003 and late 2007, assume 2005.0, positional
# crossmatches look to require a large radius, try 5"
echo "\nLooking for GALEX DR5 entry"
epoch=2005.0
cogl=$(mysql $db -N -e "SELECT CONCAT(raj2000 + ($epoch-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600.,',',dej2000 + ($epoch-2000.0) * pmde/1e3/3600.) from sdb_pm where sdbid = '$sdbid';")
echo $cogl
vizquery -site=$site -mime=votable -source=II/312/ais -c.rs=5 -sort=_r -out.max=1 -out.add=_r -out.add=objid -out.add=Fflux -out.add=e_Fflux -out.add=Nflux -out.add=e_Nflux -c="$cogl" > $ft
$stilts tjoin nin=2 in1=$fp ifmt1=votable icmd1='keepcols sdbid' in2=$ft ifmt2=votable icmd2='colmeta -name r_fov r.fov' ocmd='random' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=galex write=$mode

# Tycho-2, query against 1991.25 position. add integer version of tyc2 id for matching
echo "\nLooking for Tycho-2 entry"
epoch=1991.25
coty=$(mysql $db -N -e "SELECT CONCAT(raj2000 + ($epoch-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600.,',',dej2000 + ($epoch-2000.0) * pmde/1e3/3600.) from sdb_pm where sdbid = '$sdbid';")
echo $coty
vizquery -site=$site -mime=votable -source=I/259/tyc2 -c.rs=$rad -sort=_r -out.max=1 -out.add=_r -out.add=e_BTmag -out.add=e_VTmag -out.add=prox -out.add=CCDM -c="$coty" > $ft
$stilts tjoin nin=2 in1=$fp ifmt1=votable icmd1='keepcols sdbid' in2=$ft ifmt2=votable icmd2='colmeta -name RA_ICRS_ RA(ICRS)' icmd2='colmeta -name DE_ICRS_ DE(ICRS)' ocmd='random' ocmd='addcol -before _r tyc2id concat(toString(tyc1),concat(\"-\",concat(toString(tyc2),concat(\"-\",toString(tyc3)))))' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=tyc2 write=$mode

# Gaia, query against 2015 position
echo "\nLooking for Gaia entry"
epoch=2015.0
coga=$(mysql $db -N -e "SELECT CONCAT(raj2000 + ($epoch-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600.,',',dej2000 + ($epoch-2000.0) * pmde/1e3/3600.) from sdb_pm where sdbid = '$sdbid';")
echo $coga
vizquery -site=$site -mime=votable -source=I/337/gaia -c.rs=$rad -sort=_r -out.max=1 -out.add=_r -out.add=e_pmRA -out.add=e_pmDE -out.add=epsi -out.add=sepsi -c="$coga" > $ft
$stilts tjoin nin=2 in1=$fp ifmt1=votable icmd1='keepcols sdbid' in2=$ft ifmt2=votable icmd2='colmeta -name _FG_ <FG>' icmd2='colmeta -name e__FG_ e_<FG>' icmd2='colmeta -name _Gmag_ <Gmag>' ocmd='random' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=gaia write=$mode

# 2MASS, mean epoch of 1999.3, midway through survey 2006AJ....131.1163S
echo "\nLooking for 2MASS entry"
epoch=1999.3
cotm=$(mysql $db -N -e "SELECT CONCAT(raj2000 + ($epoch-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600.,',',dej2000 + ($epoch-2000.0) * pmde/1e3/3600.) from sdb_pm where sdbid = '$sdbid';")
echo $cotm
vizquery -site=$site -mime=votable -source=2mass -c.rs=$rad -sort=_r -out.max=1 -out.add=_r -c="$cotm" > $ft
$stilts tjoin nin=2 in1=$fp ifmt1=votable icmd1='keepcols sdbid' in2=$ft ifmt2=votable ocmd='random' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=2mass write=$mode

# ALLWISE, assume 2010.3, midway through cryo lifetime
echo "\nLooking for ALLWISE entry"
epoch=2010.3
cowise=$(mysql $db -N -e "SELECT CONCAT(raj2000 + ($epoch-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600.,',',dej2000 + ($epoch-2000.0) * pmde/1e3/3600.) from sdb_pm where sdbid = '$sdbid';")
echo $cowise
vizquery -site=$site -mime=votable -source=II/328/allwise -out.add=_r -c.rs=$rad -sort=_r -out.max=1 -c="$cowise" > $ft
$stilts tjoin nin=2 in1=$fp ifmt1=votable icmd1='keepcols sdbid' in2=$ft ifmt2=votable ocmd='random' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=allwise write=$mode

# AKARI IRC, assume 2007.0, midway through survey
echo "\nLooking for AKARI IRC entry"
epoch=2007.0
coirc=$(mysql $db -N -e "SELECT CONCAT(raj2000 + ($epoch-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600.,',',dej2000 + ($epoch-2000.0) * pmde/1e3/3600.) from sdb_pm where sdbid = '$sdbid';")
echo $coirc
vizquery -site=$site -mime=votable -source=II/297 -out.add=_r -c.rs=$rad -sort=_r -out.max=1 -c="$coirc" | grep -v "^#" > $ft
$stilts tjoin nin=2 in1=$fp ifmt1=votable icmd1='keepcols sdbid' in2=$ft ifmt2=votable ocmd='random' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=akari_irc write=$mode

# SEIP, epoch less certain, roughly 2006.9 for mid-mission so use AKARI
echo "\nLooking for SEIP entry"
epoch=2006.9
cosp=$(mysql $db -N -e "SELECT CONCAT(raj2000 + ($epoch-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600.,',',dej2000 + ($epoch-2000.0) * pmde/1e3/3600.) from sdb_pm where sdbid = '$sdbid';")
echo $cosp
curl -s "http://irsa.ipac.caltech.edu/cgi-bin/Gator/nph-query?catalog=slphotdr4&spatial=cone&radius=$rad&outrows=1&outfmt=3&objstr=$cosp" > $ft
$stilts tjoin nin=2 in1=$fp ifmt1=votable icmd1='keepcols sdbid' in2=$ft ifmt2=votable icmd2='colmeta -name dec_ dec' ocmd='random' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=seip write=$mode

# look for IRS spectra in the observing log
echo "\nLooking for IRS staring observation in Spitzer log"
epoch=2006.9
irsra=$(mysql $db -N -e "SELECT raj2000 + ($epoch-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600. from sdb_pm where sdbid = '$sdbid';")
irsde=$(mysql $db -N -e "SELECT dej2000 + ($epoch-2000.0) * pmde/1e3/3600. from sdb_pm where sdbid = '$sdbid';")
$stilts sqlclient db='jdbc:mysql://localhost/'$sdb user=$user password=$password sql="SELECT sdbid,raj2000 + (2006.9-2000.0) * pmra/1e3/cos(dej2000*pi()/180.0)/3600. as ra_ep2006p9,dej2000 + (2006.9-2000.0) * pmde/1e3/3600. as de_ep2006p9 from sdb_pm where sdbid = '$sdbid'" ofmt=votable > $fp

$stilts sqlclient db='jdbc:mysql://localhost/photometry'$ssl user=$user password=$password sql="SELECT name,ra,dec_,aor_key,'irsstare' as instrument, '2011ApJS..196....8L' as bibcode, 0 as private from spitzer_obslog where ra between $irsra-5.0 and $irsra+5.0 and dec_ between $irsde-5.0 and $irsde+5.0 and aot='irsstare'" ofmt=votable > $ft
$stilts tmatch2 in1=$fp ifmt1=votable in2=$ft ifmt2=votable ocmd='keepcols "sdbid instrument aor_key bibcode private"' matcher=skyellipse values1='ra_ep2006p9 de_ep2006p9 5.0 5.0 0.0' values2='ra dec_ 5.0 5.0 0.0' params='2' omode=tosql protocol=mysql db=$sdb user=$user password=$password dbtable=spectra find=all write=append

# clean up
rm $fp
rm $ft
rm $ft2

# note success (or at least completion)
mysql $db -N -e "INSERT INTO sdb_import_finished (sdb) VALUES ('$sdbid');"

echo "\nDone"
echo "------- db-insert-one.sh -------"
