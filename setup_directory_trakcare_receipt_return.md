# Setup Directory Export Receipt & Return ke TrakCare

Interface **Good Receive / Return** dari APEX (Oracle Fusion) ke TrakCare via text file di server DB.

| Item | Nilai |
|---|---|
| Server | `rspidev` |
| Folder Receipt | `/integration/oracletotc/ggreceive/export` |
| Folder Return | `/integration/oracletotc/ggreturn/export` |
| Directory Receipt | `EXPORT_DIR_RECEIPT_ARCH` |
| Directory Return | `EXPORT_DIR_RETURN_ARCH` |
| Schema | `XNRSPI` |
| Package | `XRSPI_AP_RECEIVE_PKG` |

---

## Langkah 0 – Cek kondisi awal (read-only)

Login OS sebagai `opc`:

```bash
ls -ld /integration /integration/tctooracle /integration/tctooracle/itemmaster
ls -ld /integration/oracletotc
```

> `/integration` milik `root` (`rwxr-xr-x`), sehingga user `opc` maupun `oracle` **tidak bisa** membuat folder langsung di dalamnya (`Permission denied`). Folder harus dibuat dengan `sudo`.

---

## Langkah 1 – Buat folder di server (OS, user `opc`)

```bash
# Buat folder (oleh root via sudo)
sudo mkdir -p /integration/oracletotc/ggreceive/export
sudo mkdir -p /integration/oracletotc/ggreturn/export

# Serahkan HANYA folder baru ke oracle (tanpa -R agar folder lain tidak terpengaruh)
sudo chown oracle /integration/oracletotc
sudo chown oracle /integration/oracletotc/ggreceive
sudo chown oracle /integration/oracletotc/ggreceive/export
sudo chown oracle /integration/oracletotc/ggreturn
sudo chown oracle /integration/oracletotc/ggreturn/export

# Hak akses
sudo chmod 755 /integration/oracletotc/ggreceive/export
sudo chmod 755 /integration/oracletotc/ggreturn/export

# Cek hasil
ls -ld /integration/oracletotc /integration/oracletotc/*/ /integration/oracletotc/*/export
```

Semua folder di bawah `oracletotc` harus ber-owner `oracle`.

> **Catatan hak akses**
> - `755` (`rwxr-xr-x`): TrakCare hanya bisa **membaca** file.
> - Jika TrakCare perlu **memindahkan/menghapus** file setelah diambil, ubah folder `export` ke `2775` dengan group yang juga dimiliki user `trakcare` (pola sama dengan `/integration/tctooracle/itemmaster`).

---

## Langkah 2 – Tes tulis dari OS sebagai user `oracle`

```bash
sudo su oracle

touch /integration/oracletotc/ggreceive/export/test_os.txt
touch /integration/oracletotc/ggreturn/export/test_os.txt
ls -l /integration/oracletotc/ggreceive/export /integration/oracletotc/ggreturn/export

rm /integration/oracletotc/ggreceive/export/test_os.txt
rm /integration/oracletotc/ggreturn/export/test_os.txt
exit
```

---

## Langkah 3 – Buat DIRECTORY object (login sebagai **SYS**)

```sql
CREATE OR REPLACE DIRECTORY EXPORT_DIR_RECEIPT_ARCH AS '/integration/oracletotc/ggreceive/export';

CREATE OR REPLACE DIRECTORY EXPORT_DIR_RETURN_ARCH  AS '/integration/oracletotc/ggreturn/export';

GRANT READ, WRITE ON DIRECTORY EXPORT_DIR_RECEIPT_ARCH TO XNRSPI;

GRANT READ, WRITE ON DIRECTORY EXPORT_DIR_RETURN_ARCH  TO XNRSPI;
```

### Verifikasi directory

```sql
SELECT *
  FROM all_directories
 WHERE directory_name IN ('EXPORT_DIR_RECEIPT_ARCH', 'EXPORT_DIR_RETURN_ARCH');
```

### Verifikasi grant

```sql
SELECT grantee, privilege, table_name
  FROM all_tab_privs
 WHERE table_name IN ('EXPORT_DIR_RECEIPT_ARCH', 'EXPORT_DIR_RETURN_ARCH', 'FILES_DIR')
 ORDER BY table_name;
```

Hasil yang diharapkan: `XNRSPI` memiliki `READ` dan `WRITE` pada kedua directory.

---

## Langkah 4 – Tes UTL_FILE dari database (login sebagai **XNRSPI**)

Jalankan **satu per satu** dan pastikan masing-masing berhasil sebelum lanjut.

### 4a. Tulis file ke folder Receipt

```sql
SET SERVEROUTPUT ON;
DECLARE
  f utl_file.file_type;
BEGIN
  f := utl_file.fopen('EXPORT_DIR_RECEIPT_ARCH', 'test_db.txt', 'W');
  utl_file.put_line(f, 'test receipt');
  utl_file.fclose(f);
  dbms_output.put_line('OK');
END;
/
```

### 4b. Tulis file ke folder Return

```sql
SET SERVEROUTPUT ON;
DECLARE
  f utl_file.file_type;
BEGIN
  f := utl_file.fopen('EXPORT_DIR_RETURN_ARCH', 'test_db.txt', 'W');
  utl_file.put_line(f, 'test return');
  utl_file.fclose(f);
  dbms_output.put_line('OK');
END;
/
```

Cek di server:

```bash
ls -l /integration/oracletotc/ggreceive/export /integration/oracletotc/ggreturn/export
```

### 4c. Tes rename (dipakai package: `.tmp` → `.txt`)

```sql
BEGIN
  utl_file.frename('EXPORT_DIR_RECEIPT_ARCH', 'test_db.txt',
                   'EXPORT_DIR_RECEIPT_ARCH', 'test_db_rename.txt', FALSE);
END;
/
```

### 4d. Hapus file tes

```sql
BEGIN
  utl_file.fremove('EXPORT_DIR_RECEIPT_ARCH', 'test_db_rename.txt');
  utl_file.fremove('EXPORT_DIR_RETURN_ARCH',  'test_db.txt');
END;
/
```

> `fremove` akan error **ORA-29283** jika file yang dihapus tidak ada. Pastikan langkah 4a–4c sudah berhasil dan nama file sesuai.

---

## Langkah 5 – DDL pendukung (login sebagai **XNRSPI**)

```sql
ALTER TABLE xnrspi_rcv_hdr_receipt_return ADD (
  export_file_name  VARCHAR2(100),
  export_date       DATE,
  export_message    VARCHAR2(4000)
);
```

Cek sequence, buat hanya jika belum ada:

```sql
SELECT sequence_name FROM user_sequences WHERE sequence_name = 'XRSPI_RCP_RTN_SEQ';

CREATE SEQUENCE xrspi_rcp_rtn_seq
  START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9999 CYCLE CACHE 20;
```

> `MAXVALUE 9999 CYCLE` wajib karena nama file memakai `LPAD(seq, 4, '0')`.

---

## Langkah 6 – Compile package (login sebagai **XNRSPI**)

Jalankan script `xrspi_ap_receive_pkg.sql` (spec + body), lalu cek error:

```sql
SELECT type, line, position, text
  FROM user_errors
 WHERE name = 'XRSPI_AP_RECEIVE_PKG'
 ORDER BY type, sequence;
```

Hasil harus kosong.

---

## Langkah 7 – Tes package

### 7a. Siapkan data

```sql
SELECT trx_header_id, receipt_number, status, organization_id, export_date
  FROM xnrspi_rcv_hdr_receipt_return
 WHERE trx_header_id = 16;
```

Pastikan `status = 'SUCCEEDED'` dan `export_date IS NULL`.

### 7b. Jalankan

```sql
BEGIN
  xrspi_ap_receive_pkg.sp_create_receive(p_trx_header_id => 16);
END;
/
```

### 7c. Cek hasil di database

```sql
SELECT trx_header_id, export_file_name, export_date, export_message
  FROM xnrspi_rcv_hdr_receipt_return
 WHERE trx_header_id = 16;
```

Diharapkan: `export_file_name` & `export_date` terisi, `export_message` kosong.

### 7d. Cek file di server

```bash
ls -l /integration/oracletotc/ggreceive/export/
cat /integration/oracletotc/ggreceive/export/Good_Receive_*.txt
```

Diharapkan:
- Baris pertama = jumlah baris detail
- Baris detail 21 kolom dipisah `^`, docket `PI<receipt_number>`
- Tidak ada file `.tmp` tertinggal

### 7e. Tes tidak dobel

Jalankan ulang langkah 7b → **tidak boleh** ada file baru (karena `export_date` sudah terisi).

### 7f. Reset untuk tes ulang

```sql
UPDATE xnrspi_rcv_hdr_receipt_return
   SET export_file_name = NULL,
       export_date      = NULL,
       export_message   = NULL
 WHERE trx_header_id = 16;
COMMIT;
```

Hapus juga file tes di folder export agar tidak diambil TrakCare.

---

## Langkah 8 – Pasang di APEX

Page **Create Receipt**:

| Komponen | Setting |
|---|---|
| Process | Type **Execution Chain**, Run in Background = **Yes**, sequence setelah process Create Receipt |
| Server-side Condition | Rows returned: `SELECT 1 FROM xnrspi_rcv_hdr_receipt_return WHERE trx_header_id = :P1005_TRX_HEADER_ID AND status = 'SUCCEEDED'` |
| Child process | Type **Execute Code**, Execution Chain = process di atas |

PL/SQL child process:

```sql
xrspi_ap_receive_pkg.sp_create_receive(p_trx_header_id => :P1005_TRX_HEADER_ID);
```

---

## Troubleshooting

| Error | Penyebab | Solusi |
|---|---|---|
| `mkdir: Permission denied` | `/integration` milik root | Gunakan `sudo mkdir` (Langkah 1) |
| `ORA-29280 invalid directory path` | Nama directory salah / belum di-grant | Cek Langkah 3 |
| `ORA-29283 invalid file operation` saat `fopen` | Folder OS tidak ada / owner bukan `oracle` | Cek Langkah 1–2, `namei -l <path>` |
| `ORA-29283` saat `fremove` | File yang dihapus tidak ada | Pastikan nama file benar & sudah dibuat |
| `export_message` terisi | Error saat proses package | Baca pesan, perbaiki, reset (7f), jalankan ulang |
