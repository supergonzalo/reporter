#!/usr/bin/perl

package main;

#S: util #################################################################
$LOG_LVL_MAX=9;

use Data::Dumper;

sub logm {
	my ($type,$lvl,$fmt)= @_;
	if ($lvl<= $LOG_LVL_MAX) {
		open(LOGF,">>AppMercado.log");
		local $Data::Dumper::Indent= 0;
		local $Data::Dumper::Terse= 1;
		$fmt=~ s/\#(\d+)/Dumper($_[2+$1])/gse;
		print LOGF "$type:$lvl:$fmt\n";
		close(LOGF);
	}
}

sub d {
	#D: mutate a dictionary, copy last param, then apply kv changes
	my %r= (@_ % 2)	? %{pop(@_)} : ();
	for (my $i=0; $i<@_; $i+=2) {
		$r{$_[$i]}= $_[$i+1];
	}
	return \%r;
}

*ourtime= $ENV{EMU_TIME} ? (($ENV{EMU_TIME} =~ /^#(.*)/) ? &{sub { my @r= split(":",$_[0]); sub { @r }}}($1) : sub { split("\t",`$ENV{EMU_TIME}`) }) : sub { localtime() };

sub hoy {
	my @t= ourtime();
	return sprintf("%04d%02d%02d",$t[5]+1900,$t[4]+1,$t[3]);
}

sub now(){
        my @t= ourtime();
        return sprintf("%04d%02d%02d%02d%02d%02d",$t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]);
}


#S: output ################################################################

sub kvPrint {
	my ($kv)= @_;
	print join(", ", map("'$_' => '$$kv{$_}'", keys(%$kv))) . "\n";
}

sub kvPrintTsv {
	my ($kv,$keys,$pfx)= @_;
	unless($keys) {
		$keys= {};
		my $s="";
		foreach my $t (keys(%$kv)) {
			print $s;
			$$keys{$t}= [ keys(%{$$kv{$t}}) ];
			print $pfx . join("\t",@{$$keys{$t}});
			$s="\t";
		}
		print "\n";
	} 
	my $s= $pfx ? "$pfx\t" : "";
	foreach my $t (keys(%$keys)) {
		print $s;
		print join("\t", map("$$kv{$t}{$_}", @{$$keys{$t}}));
		$s="\t";
	}
	print "\n";
	return $keys;
}

sub kvPrintTsvSingle {
	my ($kv,$keys)= @_;
	unless($keys) {
		$keys= [ keys(%$kv) ];
		print join("\t",@$keys) . "\n";
	} 
	print join("\t", map("$$kv{$_}", @$keys)) . "\n";
	return $keys;
}
#S: input #################################################################
sub inputParseDate {
	my ($s)= @_;
	my $rv=undef; my $rmsg= "ERROR";
	if ($s =~ /^(\d+)\D+(\d+)(?:\D+(\d+))?$/) {
		my $d=$1;
		my $m=$2 || ((ourtime())[4]+1);
		my $y= $3 || ((ourtime())[5]+1900);
		#XXX: validar rangos, completar año si no esta
		#XXX: los defaults (y si los usuamos) debe definirse a nivel app
		$rv= sprintf("%04d%02d%02d",$y,$m,$d); $rmsg="";
	}
	return ($rv, $rmsg, $s);
}

#S: db ###################################################################
use DBI;
$DB_CX_DEFAULT= 'DBI:SQLite:app.deptos.db';


sub dbh {
	my ($cx)= @_;
	$cx ||= $DB_CX_DEFAULT; #XXX: ojo, debe ser el mismo que en db()
	my $r= DBI->connect_cached($cx, { RaiseError => 0 } ); 
	if (!$r) { 
		logm("ERR",1,"DB '$cx' CONNECT FAILED '($DBI::err) $DBI::errstr'"); 
	}
	return $r;
}

my $tx=0;
my %txCx= ();
sub dbTxStart {
	my ($prevTx)= @_;
	my $r= $prevTx;
	unless ($r) {
		my $d= dbh();
		if ($d) { 
			$d->begin_work();
			$tx++;
			$txCx{$tx}= $d;
			logm("DBG",1,"DB TX=$tx BEGIN"); 
			$r= $tx;	
		}
	}
	return $r;
}

sub dbTxCommit {	
	my ($tx, $prevTx, $r)= @_;
	unless ($prevTx) {
		my $d= $txCx{$tx}; delete($txCx{$tx});
		$r= ($d && $d->commit()) ? $r  : 0;
		logm("DBG",1,"DB TX=$tx COMMIT '$r'"); 
	}
	return $r;
}

sub dbTxRollback {	
	#XXX: que hacemos si beginT call F ( F hace rollback ) caller sigue usando TX ? lo ideal seria ignorar statements siguientes
	my ($tx)= @_;
	my $d= $txCx{$tx}; delete($txCx{$tx});
	my $r= $d ? $d->rollback() : 0;
	logm("DBG",1,"DB TX=$tx ROLLBACK '$r'"); 
	return $r;
}

sub db {
	my ($sql,$vals,$tx,$cx)= @_;
	my $r= undef;
	$cx ||= $DB_CX_DEFAULT;
	logm("DBG",9,"DB TX=$tx '$cx' SQL=#1",$sql); 
	my $dbh= $tx ? $txCx{$tx} : dbh($cx);
	if ($dbh) { 
		my $sth= $dbh->prepare_cached($sql);
		if ($sth) {
			my $rv= $sth->execute(@$vals);
			$r= ($rv && $sth->{NUM_OF_FIELDS}>0) ?  $sth : $rv;
		}
	}
	if ($r) { 
		if ($sql =~ /^INSERT/) {
			$r= $dbh->selectrow_array("select last_insert_rowid()");
		}
		logm("NFO", 5,"DB TX=$tx '$cx' EXEC SQL=#1 VALS=#2 R='$r'", $sql, $vals );
	}
	else { logm("ERR", 2,"DB TX=$tx '$cx' EXEC '#1' VALS=#2 R='$r' '($DBI::err) $DBI::errstr'", $sql, $vals);
	}
	return $r;
}


#S: db prolog like #########################################################
use LSql;

{
	%pTables= ();
	sub dbMeta {
		my ($kv, $tx, $cx)= @_;
		my $t= $$kv{'T'};

		if (!$pTables{$t}) {
			my @k= keys(%$kv);
			my %dml= exprToDML(exprFromData($kv));
			$pTables{$t}= $dml{$t};
			my $sqlCreate= $dml{$t}{CREATE};
			db($sqlCreate,undef,$tx,$cx);
			$pTables{$t}{"cols"}= \@k;
			logm("DBG",9,"DB TABLE=#1 #2",$t,$pTables{$t});
		}

		return $pTables{$t};
	}
}

sub dbAdd {
	my ($kv, $tx, $cx)= @_;
	my $m= dbMeta($kv,$tx,$cx);
	my ($sql, $params)= sqlAndParams($$m{"INSERT"});
	my %kvx= %$kv;
	my $r= db($sql,[@kvx{@$params}],$tx,$cx);
	return $r && $id;
}

sub dbDel {
	my ($kv, $tx, $cx)= @_;
	my $t= $$kv{'T'};
	my @k= keys(%$kv);
	my $sql= "DELETE FROM $t WHERE " . join(" AND ", map("$_=?", @k ) ) . ";";
	my @v= @$kv{@k};
	db($sql, \@v, $tx, $cx);
}	

sub dbChg {
	my ($kv, $kvNew, $tx, $cx)= @_;
	my $t= $$kv{'T'};
	my @k= keys(%$kv);
	if (exists($$kvNew{'DATAVER'})) {
		$$kvNew{'DATAVER'}= $$kv{'DATAVER'}+1;
	}

	my @kNew= keys(%$kvNew);

	my $sql= "UPDATE $t SET " . join(", ", map("$_=?", @kNew ) ) . " WHERE " . join(" AND ", map("$_=?", @k ) ) . ";";
	my @v=(@$kvNew{@kNew} , @$kv{@k}) ;
	db($sql,\@v,$tx, $cx);
}

sub dbSet {
	my ($kv, $kvOld, $tx, $cx)= @_;
	my $r=0;
	if ($kvOld) {
		$r= dbChg($kvOld,$kv,$tx, $cx);
	}
	unless ($r>0) {
		$r= dbAdd($kv,$tx, $cx);
	}
	return $r;
}

sub dbFind {
	my ($expr,$kv,$order,$tx,$cx)= @_;
	$expr||= exprFromData($kv);	
	my $sqlNP= exprToSelect($expr,1);
	my ($sql, $params)= sqlAndParams($sqlNP);
	if ($order && @$order) {
		$sql.= " ORDER BY " . join(", ",@$order);
	} 
	$sql.=";";
	my @vals= ();
	foreach my $k (@$params) {
		push @vals, $$kv{$k};
	}
	logm("DBG",9,"DBFIND SQL='#1' PARAMS=#2 VALS=#3 KV=#4",$sql,$params,\@vals,$kv);
	db($sql, \@vals, $tx, $cx);
}

#S: db prolog like UTILS ######################################################
$END= {};

sub dbFindFold {
	my ($expr, $kv, $order, $sub, $d, $tx, $cx)= @_;
	#D: invoca $sub para cada fila resultante de la consulta $expr con las variables instanciada con los valores de $kv ordenadas por las columnas especificadas en $order (ver ejemplos con kvPrintTsv)
	my $rs = dbFind( $expr, $kv, $order, $tx, $cx );
	my $row;

	my @names= @{$rs->{NAME}};
	my %types= ();
	my $iLast=0; my $cur= '';
	for (my $i=0; $i<@names; $i++) {
		logm("DBG",9,"DB NAMES N=#1 I=#2 CUR=#3",$names[$i],$i,$cur);
		if ($names[$i]=~ /^TaBlE_(.*)/) {
			logm("DBG",9,"DB NAMES MATCH N=#1 I=#2 CUR=#3",$names[$i],$i,$cur);
			if ($cur) { $types{$cur}= [$iLast,$i-1] };
			$cur= $1; $iLast= $i+1;
		}
	}
	if ($cur) { $types{$cur}= [$iLast,@names-1] };
	logm("DBG",9,"DB NAMES TYPES=#1 FROM NAMES=#2",\%types,\@names);
	#A: types = typename -> [ start, end ]

	my $rowa;
	ROW: while ($rowa= $rs->fetchrow_arrayref) {
		my $row= {};
		while (($t,$idx)= each(%types)) {
			my %h= ();
			my @hk= @names[$$idx[0] .. $$idx[1]];
			my @hv= @$rowa[$$idx[0] .. $$idx[1]];
			@h{@hk}= @hv;
			logm("DBG",9,"DB ROW K=#1 V=#2 T=#3",\@hk,\@hv,\%h);
			$$row{$t}= \%h;
		}
		if ($d ne $END) { $d= &$sub($row, $d,$tx,$cx); }
		else { $rs->finish(); last ROW; }
	}
	return $d;
}

sub dbFindN {
	my ($expr, $kv, $order, $cnt, $tx, $cx)= @_;
	my @r;
	my $cb= sub { 
		my ($kv)= @_;
		push @r, $kv;
		return @r<$cnt ? '' : $END;
	};

	dbFindFold( $expr, $kv, $order, $cb, undef, $tx, $cx );
	return \@r;
}

#S: Marshalling ################################################################
use Storable;
use MIME::Base64;
use CGI::Session;
%Ctxt= ();

sub marshallCtxt {
	my ($ctxt)= @_;
	if ($ctxt && $Ctxt{$ctxt}) { } 
	else { 
		my $s= new CGI::Session("driver:file",$ctxt,{ Directory => '/tmp' });
		$ctxt= $s->id();	
		$Ctxt{$ctxt}= $s;
	}
	return $ctxt;
}

sub marshall {
	my ($t, $ctxt)= @_;
	#XXX: hook to marshall subs, db queries, etc.

	my $r="";
	if (exists($$t{AID})) {
		$r="I$$t{T}_$$t{AID}_$$t{DATAVER}";
	}
	elsif ($ctxt) {
		my $lastId= $Ctxt{$ctxt}->param("id_last") || 0;
		$lastId++;
		$Ctxt{$ctxt}->param("id_last", $lastId);
		$Ctxt{$ctxt}->param($lastId."",$t);
		$Ctxt{$ctxt}->flush();
		$r="S" . $lastId;
	}
	else {
		$r= "E" . encode_base64(Storable::nfreeze($t));	
		$r=~ s/\r?\n//g;
	}
	logm("DBG",9,"MARSHALL OtoID id='#1' ctxt='$ctxt' r='#2'",$r,$t);
	return $r;
}

sub unmarshall {
	my ($o, $ctxt)= @_;
	my $r;
	if ($o=~ /^I(\w+?)_(\d+)/) {
		$r= (dbFindN("$1.AID = ?id", { id => $2 }))[0];
	}
	elsif ($o=~ /^S(\d+)$/) {
		my $id= $1."";
		$Ctxt{$ctxt} ||= new CGI::Session("driver:file",$ctxt, { Directory => '/tmp' });
		$r= $Ctxt{$ctxt}->param($id);
	}
	else {
		$r= Storable::thaw(decode_base64(substr($o,1)));
	}
	logm("DBG",9,"MARSHALL IDtoO id='$o' ctxt='$ctxt' r='$r'");
	return $r;
}


#S: App Turnos #################################################################

#Obtener en que franja horaria estamos en base a la hora
sub get_franja {
   my $hora=now();
   $hora=~/\d{8}(\d{2})\d+/;
   $1 > 9 ? ($1 > 13 ? ($1 > 20 ? return 'N' : return 'T') : return 'M') : return '-';
   }


@TNombres= qw/Hugo Juan Pedro Mauricio Gonzalo Pepe Luis Maria Ana Luisa Graciana Lorena/;
@TApellidos= qw/Perez Gomez Sanchez Rodriguez Gonzalez Cappella Salgueiro Anchorena Alvear Roca Pellegrini Cangallo/;

@Cobertura= qw/OSDE OMINT OSPLAD OSMECON OSUTGRA SWISSMEDICAL MEDICUS GALENO/;
@Especialidad= qw/Oftalmología Traumatología Ginecología Odontología Geriatría Pediatría Urología Endocrinología Obstetricia Oncología Nefrología Neurología Psiquiatría Gastroenterología Otorrinonaringología/;
@Establecimiento= qw/(cualquiera) Bazterrica Trinidad Suizo Otamendi Alemán Británico Español ModeloDeMorón/;

@EstadoTurno= qw/Libre Pedido Asignado Confirmado Cancelado/;
@AccionTurno= qw/Rechazar Confirmar Eliminar/;

@DiasSem= qw/Lunes Martes Miércoles Jueves Viernes Sábado Domingo/;
@DiasSemCorto= qw/Lun Mar Mié Jue Vie Sáb Dom/;

sub turno {
	my ($recurso, $fecha, $hora, $lugar, $usuario, $estado, $especialidad)= @_;
	{ T => 'turno', RECURSO => $recurso, FECHA => $fecha, HORA => $hora, LUGAR => $lugar, USUARIO => $usuario, ESTADO => $estado, ESPECIALIDAD => $especialidad}, 
}

sub turnoK {
	my ($t)= @_;
	my %r= ();
	foreach $c (qw/T RECURSO FECHA HORA/) {
		$r{$c}= $$t{$c};
	}
	return \%r;
}

sub turnoCalc {
	my ($t)= @_;
	my %r= ();
	
	if ($$t{ESTADO} eq 'LIBRE') {
		$r{Eliminar}= 1;	
	}
	elsif ($$t{ESTADO} eq 'PEDIDO') {
		$r{Rechazar}= 1;
		$r{Confirmar}= 1;
		$r{Eliminar}= 1;
	}
	elsif ($$t{ESTADO} eq 'ASIGNADO' || $t{ESTADO} eq 'CONFIRMADO') {
		$r{Rechazar}= 1;
		$r{Eliminar}= 1;
	}
	return %r;
}

sub turnosQ {
	my ($kv,$order,$sub,$d,$tx,$cx)= @_;
	my @estados= @{ $$kv{estados} };
	my $exprEstados= @estados ? " AND ( " . join(" OR ", map("estado= \"$_\"", @estados)) . ")" : "";
	dbFindFold('t="turno" AND fecha >= ?fecha_desde AND fecha <= ?fecha_hasta ' . $exprEstados, $kv, $order,$sub, $d, $tx,$cx);
}

sub turnoRegistrar {
	my ($turno, $tx)= @_;
	#D: agrega un turno a la lista, puede estar libre o asignado a un usuario. Si YA EXISTE, puede cambiar el usuario de LIBRE a otro, el LUGAR, y el ESTADO

	my $r;

	my $k= turnoK($turno);
	my $txMy= dbTxStart($tx);
	my $p= dbFindN("",$k,undef,1,$txMy);	
	if (@$p<1 || $$p[0]{USUARIO} eq 'LIBRE') {
		$r= dbSet( $turno,	$k, $txMy)	
	}
	$r= dbTxCommit($txMy,$tx,$r);

	return $r;
}

sub usuarioRegistrar {
	my ($u, $tx)= @_;
	#D: agrega un usuario

	my $r;

	my $txMy= dbTxStart($tx);
	my $p= dbFindN('T="USUARIO" AND ( desc=?DESC OR email=?EMAIL )',$u,undef,1,$txMy);	
	if (@$p<1) {
		$r= dbAdd($u, $txMy)	
	}
	$r= dbTxCommit($txMy,$tx,$r);

	return $r;
}

sub recursoRegistrar {
	my ($u, $tx)= @_;
	#D: agrega un usuario

	my $r;

	my $txMy= dbTxStart($tx);
	my $p= dbFindN('T="RECURSO" AND desc=?DESC',$u,undef,1,$txMy);	
	if (@$p<1) {
		$r= dbAdd($u, $txMy)	
	}
	$r= dbTxCommit($txMy,$tx,$r);

	return $r;
}


1;

